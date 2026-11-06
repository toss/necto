//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoMacService

/// The exporter document lives independently of feature panels and their windows.
@MainActor
final class NectoExporterRuntime {
    private var identity: String?
    private(set) var page: NectoWebPage?
    private var diagnostics: NectoDiagnosticsLog?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownWork: Task<Void, Never>?
    private var shutdownTimer: Task<Void, Never>?
    private var shutdownCompletion: CheckedContinuation<Void, Never>?

    func synchronize(
        exporter: NectoInstalledExporter?,
        registry: NectoPluginRegistry,
        eventDispatcher: NectoEventDispatcher,
        diagnostics: NectoDiagnosticsLog
    ) {
        let nextIdentity = exporter.map {
            "\($0.id)|\($0.principal?.sourceIdentity ?? "")|\($0.contentIdentity)"
        }
        guard shutdownTask == nil else {
            if identity != nextIdentity { finishShutdown() }
            return
        }
        guard identity != nextIdentity else { return }
        page?.invalidate()
        page = nil
        identity = nextIdentity
        self.diagnostics = diagnostics
        guard let exporter else { return }
        let page = NectoWebPage(
            package: exporter.package,
            registry: registry,
            target: nil,
            locale: NectoL10n.languageCode,
            eventDispatcher: eventDispatcher,
            diagnostics: diagnostics
        )
        page.setVisible(false, find: nil, scale: 1)
        self.page = page
    }

    /// Normal app termination only. Removing or replacing an exporter still
    /// invalidates it immediately through synchronize.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { await performShutdown() }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        guard let page else { return }
        let deadlineAt = Date().addingTimeInterval(5)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        await withCheckedContinuation { completion in
            shutdownCompletion = completion
            shutdownTimer = Task { [weak self] in
                do { try await clock.sleep(until: deadline) }
                catch { return }
                self?.finishShutdown()
            }
            shutdownWork = Task { [weak self] in
                do {
                    try await page.shutdownExporter(deadlineAt: deadlineAt)
                } catch {
                    if !Task.isCancelled {
                        await self?.diagnostics?.append(.failure, .exporter, "Event exporter shutdown failed")
                    }
                }
                self?.finishShutdown()
            }
        }
    }

    private func finishShutdown() {
        let completion = shutdownCompletion
        shutdownCompletion = nil
        shutdownTimer?.cancel()
        shutdownTimer = nil
        shutdownWork?.cancel()
        shutdownWork = nil
        page?.invalidate()
        page = nil
        completion?.resume()
    }
}
