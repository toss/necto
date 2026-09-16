//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Darwin
import Foundation

/// Bounded subprocess I/O. Cancellation terminates the direct child, not its descendants.
/// Completion waits for the child to exit and both output handles to close.
public enum NectoProcessRunner {
    /// Preloading one atomic pipe write cannot block before the child starts.
    public static let maximumStandardInputBytes = Int(PIPE_BUF)

    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case timedOut
        case outputLimitExceeded
        case standardInputLimitExceeded
        case readFailed(Int32)

        public var description: String {
            switch self {
            case .timedOut: "The process or its output pipes did not finish before the deadline"
            case .outputLimitExceeded: "The process exceeded its output limit"
            case .standardInputLimitExceeded: "Standard input exceeded the supported byte limit"
            case let .readFailed(code): "Could not read process output (errno \(code))"
            }
        }
    }

    public static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        standardInput: Data? = nil,
        timeoutMilliseconds: Int = 120_000,
        maximumOutputBytes: Int = 8 * 1_048_576
    ) async throws -> Output {
        guard (standardInput?.count ?? 0) <= maximumStandardInputBytes else {
            throw Failure.standardInputLimitExceeded
        }
        let running = Running(outputLimit: max(0, maximumOutputBytes))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output = try await withCheckedThrowingContinuation { continuation in
                running.start(
                    executable, arguments: arguments, environment: environment, directory: directory,
                    standardInput: standardInput, timeoutMilliseconds: timeoutMilliseconds, continuation: continuation
                )
            }
            try Task.checkCancellation()
            return output
        } onCancel: {
            running.cancel()
        }
    }

    // Mutable state, Process lifecycle and DispatchIO callbacks share this queue.
    private final class Running: @unchecked Sendable {
        private let queue = DispatchQueue(label: "im.toss.necto.process")
        private let outputLimit: Int
        private var continuation: CheckedContinuation<Output, any Error>?
        private var process: Process?
        private var channels: [DispatchIO] = []
        private var timer: DispatchSourceTimer?
        private var stdout = Data()
        private var stderr = Data()
        private var openPipes = 0
        private var exitCode: Int32?
        private var failure: (any Error)?
        private var completed = false

        init(outputLimit: Int) { self.outputLimit = outputLimit }

        func start(
            _ executable: String,
            arguments: [String],
            environment: [String: String]?,
            directory: URL?,
            standardInput: Data?,
            timeoutMilliseconds: Int,
            continuation: CheckedContinuation<Output, any Error>
        ) {
            queue.async { [self] in
                self.continuation = continuation
                guard failure == nil else { finishIfReady(); return }
                let child = Process()
                let output = Pipe()
                let errors = Pipe()
                let input = standardInput.map { _ in Pipe() }
                child.executableURL = URL(filePath: executable)
                child.arguments = arguments
                child.environment = environment ?? ProcessInfo.processInfo.environment
                child.currentDirectoryURL = directory
                child.standardInput = input?.fileHandleForReading ?? FileHandle.nullDevice
                child.standardOutput = output
                child.standardError = errors
                child.terminationHandler = { [self] terminated in
                    let code = terminated.terminationStatus
                        + (terminated.terminationReason == .uncaughtSignal ? 128 : 0)
                    queue.async { [self] in
                        exitCode = code
                        finishIfReady()
                    }
                }
                read(output.fileHandleForReading, isError: false)
                read(errors.fileHandleForReading, isError: true)
                defer {
                    try? output.fileHandleForWriting.close()
                    try? errors.fileHandleForWriting.close()
                    try? input?.fileHandleForReading.close()
                    try? input?.fileHandleForWriting.close()
                }
                do {
                    if let input, let standardInput {
                        try input.fileHandleForWriting.write(contentsOf: standardInput)
                        try input.fileHandleForWriting.close()
                    }
                    try child.run()
                    process = child
                } catch {
                    child.terminationHandler = nil
                    fail(error)
                    return
                }
                if timeoutMilliseconds > 0 {
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + .milliseconds(timeoutMilliseconds))
                    timer.setEventHandler { [weak self] in self?.fail(Failure.timedOut) }
                    self.timer = timer
                    timer.resume()
                }
            }
        }

        func cancel() {
            queue.async { [self] in fail(CancellationError()) }
        }

        private func read(_ handle: FileHandle, isError: Bool) {
            let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { [self] _ in
                try? handle.close()
                openPipes -= 1
                finishIfReady()
            }
            channel.setLimit(lowWater: 1)
            channel.setLimit(highWater: 64 * 1024)
            channels.append(channel)
            openPipes += 1
            channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
                guard !completed, failure == nil else { return }
                if let data {
                    guard data.count <= outputLimit - stdout.count - stderr.count else {
                        fail(Failure.outputLimitExceeded)
                        return
                    }
                    if isError { stderr.append(Data(data)) } else { stdout.append(Data(data)) }
                }
                if error != 0 { fail(Failure.readFailed(error)); return }
                if done {
                    channel.close()
                }
            }
        }

        private func fail(_ error: any Error) {
            guard !completed, failure == nil else { return }
            failure = error
            channels.forEach { $0.close(flags: .stop) }
            if let process, process.isRunning {
                process.terminate()
                queue.asyncAfter(deadline: .now() + .seconds(1)) { [process] in
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
            finishIfReady()
        }

        private func finishIfReady() {
            guard !completed, openPipes == 0, let continuation else { return }
            if failure != nil {
                guard process == nil || exitCode != nil else { return }
            } else {
                guard openPipes == 0, exitCode != nil else { return }
            }
            completed = true
            timer?.cancel()
            timer = nil
            channels.forEach { $0.close(flags: .stop) }
            channels.removeAll()
            process?.terminationHandler = nil
            process = nil
            self.continuation = nil
            if let failure { continuation.resume(throwing: failure) }
            else if let exitCode { continuation.resume(returning: Output(stdout: stdout, stderr: stderr, exitCode: exitCode)) }
        }
    }
}
