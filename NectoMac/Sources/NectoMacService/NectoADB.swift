//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// What the connection centre needs from ADB. ``NectoADBClient`` runs the adb tool; tests
/// supply their own.
protocol NectoADB: Sendable {
    /// Authorized devices on a USB cable and real local emulators. Wireless ADB is left out.
    func devices() async throws -> [String]
    /// The running apps on [serial] that carry a Necto socket, by package, with its name.
    func endpoints(serial: String) async throws -> [String: String]
    /// Forwards the Unix socket at [socketPath] to the device's abstract socket [name].
    func forward(serial: String, socketPath: String, name: String) async throws
    func removeForward(serial: String, socketPath: String) async
    /// The local socket paths the adb server forwards, by serial.
    func forwards() async throws -> [(serial: String, socketPath: String)]
}

/// Runs the adb tool from the Android SDK against the local adb server.
///
/// An Android app's Necto socket is an abstract socket under a random name that only
/// `adb shell run-as` can read, which needs a debuggable app. Necto reads the name,
/// forwards a private Unix socket to it, and connects there.
actor NectoADBClient: NectoADB {
    let executable: String
    private var serverStarted = false
    /// Whether a serial is on a USB cable or is a real emulator. A serial keeps its
    /// transport while it stays listed.
    private var local: [String: Bool] = [:]

    init(executable: String) {
        self.executable = executable
    }

    /// The adb in the Android SDK, if one is installed. An SDK folder chosen in Settings
    /// is the only place looked at. Without one, the SDK's usual places are checked: an
    /// app started from the Finder does not inherit the shell's PATH or its variables.
    static func locate(
        sdk: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = userHome
    ) -> String? {
        let chosen = sdk.map { ($0 as NSString).expandingTildeInPath }.flatMap { $0.isEmpty ? nil : $0 }
        let roots: [String?] = chosen.map { [$0] }
            ?? [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], home + "/Library/Android/sdk"]
        return roots.compactMap { $0 }.filter { !$0.isEmpty }
            .map { $0 + "/platform-tools/adb" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The account's own home: NSHomeDirectory follows CFFIXED_USER_HOME, which a
    /// separate Necto sets for its settings while the SDK stays where it is installed.
    private static var userHome: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    func devices() async throws -> [String] {
        if !serverStarted {
            // Necto manages its Android connections itself, so it starts the server when
            // none is running. It leaves it running on quit: other tools share it.
            _ = try await adb(["start-server"], timeoutMilliseconds: 10_000)
            serverStarted = true
        }
        let listed = Self.authorizedSerials(try await adb(["devices"]))
        local = local.filter { listed.contains($0.key) }
        var result: [String] = []
        for serial in listed {
            if local[serial] == nil {
                // A device that cannot say yet is asked again next time, and holds up no
                // other device meanwhile.
                guard let isLocal = try? await isLocal(serial) else { continue }
                local[serial] = isLocal
            }
            if local[serial] == true { result.append(serial) }
        }
        return result
    }

    /// Asks running third-party apps only. The package list and the process list each
    /// throw on failure, so a device that cannot answer is never read as one without apps.
    func endpoints(serial: String) async throws -> [String: String] {
        let packages = Self.packages(try await adb(["-s", serial, "shell", "pm", "list", "packages", "-3"]))
        let running = Self.processes(try await adb(["-s", serial, "shell", "ps", "-A", "-o", "NAME="]))
        let executable = executable
        // One run-as per app, side by side: a phone runs a few dozen apps, and asked one
        // after another they take most of a probe interval.
        let files = await withTaskGroup(of: (String, String?).self) { group in
            for package in packages.intersection(running) {
                group.addTask {
                    // run-as fails for an app that is not debuggable or has no file: that
                    // app is skipped, not the scan.
                    let output = try? await NectoProcessRunner.run(
                        executable, arguments: Self.server + ["-s", serial, "shell", "run-as", package, "cat", "no_backup/necto-endpoint"],
                        environment: Self.environment, timeoutMilliseconds: 5_000, maximumOutputBytes: 4_096
                    )
                    return (package, output?.exitCode == 0 ? output.map { String(decoding: $0.stdout, as: UTF8.self) } : nil)
                }
            }
            return await group.reduce(into: [(String, String?)]()) { $0.append($1) }
        }
        var result: [String: String] = [:]
        var unanswered = false
        for (package, contents) in files {
            guard let contents else { unanswered = true; continue }
            if let name = Self.endpointName(contents) { result[package] = name }
        }
        // A device that left also fails every run-as, so it must still answer.
        if unanswered { _ = try await adb(["-s", serial, "get-state"]) }
        return result
    }

    func forward(serial: String, socketPath: String, name: String) async throws {
        guard Self.isEndpointName(name) else { throw POSIXError(.EINVAL) }
        let output = try await NectoProcessRunner.run(
            executable, arguments: Self.server + ["-s", serial, "forward", "localfilesystem:" + socketPath, "localabstract:" + name],
            environment: Self.environment, timeoutMilliseconds: 5_000
        )
        guard output.exitCode == 0 else { throw POSIXError(.EIO) }
    }

    func removeForward(serial: String, socketPath: String) async {
        _ = try? await adb(["-s", serial, "forward", "--remove", "localfilesystem:" + socketPath])
    }

    func forwards() async throws -> [(serial: String, socketPath: String)] {
        Self.forwards(try await adb(["forward", "--list"]))
    }

    /// A cable or a real emulator: wireless ADB reaches the phone from the network, and
    /// an emulator serial is only an emulator when the device says so.
    private func isLocal(_ serial: String) async throws -> Bool {
        if serial.range(of: "^emulator-[0-9]+$", options: .regularExpression) != nil {
            return try await adb(["-s", serial, "shell", "getprop", "ro.kernel.qemu"])
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        return try await adb(["-s", serial, "get-devpath"]).hasPrefix("usb:")
    }

    /// A failed command throws: an empty answer from a device that went offline must not
    /// read as a device with no apps.
    private func adb(_ arguments: [String], timeoutMilliseconds: Int = 5_000) async throws -> String {
        let output = try await NectoProcessRunner.run(
            executable, arguments: Self.server + arguments, environment: Self.environment,
            timeoutMilliseconds: timeoutMilliseconds, maximumOutputBytes: 1_048_576
        )
        guard output.exitCode == 0 else { throw POSIXError(.EIO) }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    /// The server on this Mac, never one named by the environment: that could be a server
    /// on another machine. adb starts a server only for `localhost`; for `127.0.0.1` it
    /// refuses, as for any remote host.
    private static let server = ["-H", "localhost", "-P", "5037"]

    private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS", "ANDROID_ADB_SERVER_PORT"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    static func authorizedSerials(_ output: String) -> [String] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[1] == "device" ? String(fields[0]) : nil
        }
    }

    /// Lines of `<serial> localfilesystem:<path> <remote>`, keeping local socket forwards.
    static func forwards(_ output: String) -> [(serial: String, socketPath: String)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 3, fields[1].hasPrefix("localfilesystem:") else { return nil }
            return (fields[0], String(fields[1].dropFirst("localfilesystem:".count)))
        }
    }

    /// Lines of `package:<name>` from `pm list packages`.
    static func packages(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            let name = String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces)
            return isPackageName(name) ? name : nil
        })
    }

    /// Process names from `ps`, with a `:service` suffix dropped to leave the package.
    static func processes(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let name = String(line.split(separator: ":", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
            return isPackageName(name) ? name : nil
        })
    }

    /// The name an app wrote into its endpoint file: one line and nothing else. A second
    /// line or a stray "\r" fails the check rather than being read past.
    static func endpointName(_ contents: String) -> String? {
        let name = contents.hasSuffix("\n") ? String(contents.dropLast()) : contents
        return isEndpointName(name) ? name : nil
    }

    static func isPackageName(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+/) != nil
    }

    static func isEndpointName(_ value: String) -> Bool {
        value.wholeMatch(of: /necto\.[a-f0-9]{64}/) != nil
    }
}
