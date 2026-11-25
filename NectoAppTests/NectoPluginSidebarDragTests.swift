//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoModel
import Testing

@Suite("Plugin sidebar drag transport")
@MainActor
struct NectoPluginSidebarDragTests {
    private let source = NectoPluginSidebarState.ItemLocation(kind: .device, id: .plugin("a"), parentID: nil)

    @Test("Repeated provider requests preserve an accepted opaque transfer")
    func repeatedFactoriesRetainAcceptedOpaqueTransfer() async throws {
        let context = makeContext()
        let drag = NectoPluginSidebarDrag()
        let first = drag.provider(for: source, in: context)
        let second = drag.provider(for: source, in: context)
        let firstHandle = await text(from: first)
        let secondHandle = await text(from: second)
        #expect(firstHandle == secondHandle)
        #expect(UUID(uuidString: firstHandle ?? "") != nil)

        let receipt = AsyncStream<NectoPluginSidebarState.ItemLocation>.makeStream()
        try #require(drag.receive([first], context: context, currentContext: { context }) {
            receipt.continuation.yield($0)
        })
        let movedSource = try await receivedValue(from: receipt)
        #expect(movedSource == source)
        #expect(!drag.acceptsDrop(in: context))
    }

    @Test("External text cannot move a sidebar item")
    func externalStringCannotMove() async throws {
        let context = makeContext()
        let drag = NectoPluginSidebarDrag()
        _ = drag.provider(for: source, in: context)
        let external = NSItemProvider(object: "same names are not a handle" as NSString)
        var moved = false
        try #require(drag.receive([external], context: context, currentContext: { context }) { _ in
            moved = true
        })
        // A rejected provider load has no completion callback in the drag API.
        try await Task.sleep(for: .seconds(1))
        #expect(!moved)
    }

    @Test("The transfer is scoped to its window and context, and clearing invalidates it")
    func contextAndClearInvalidateTransfer() {
        let context = makeContext()
        let changed = makeContext(bundle: "preview-b")
        let drag = NectoPluginSidebarDrag()
        let provider = drag.provider(for: source, in: context)
        let otherWindow = NectoPluginSidebarDrag()
        #expect(!otherWindow.receive([provider], context: context, currentContext: { context }) { _ in
            Issue.record("A different window received the transfer")
        })
        #expect(!drag.acceptsDrop(in: changed))
        #expect(!drag.receive([provider], context: changed, currentContext: { changed }) { _ in
            Issue.record("A different target received the transfer")
        })
        drag.clear()
        #expect(!drag.acceptsDrop(in: context))
        #expect(drag.takeNativeSource(in: context) == nil)
    }

    @Test("A pending drop checks the current context before moving")
    func pendingDropRechecksCurrentContext() async throws {
        let context = makeContext()
        let changed = makeContext(bundle: "preview-b")
        let drag = NectoPluginSidebarDrag()
        let provider = drag.provider(for: source, in: context)
        let revalidation = AsyncStream<Void>.makeStream()

        try #require(drag.receive([provider], context: context, currentContext: {
            revalidation.continuation.yield(())
            return changed
        }) { _ in
            Issue.record("The pending drop moved after the target changed")
        })
        try await receivedValue(from: revalidation)
        #expect(!drag.acceptsDrop(in: context))
    }

    @Test("A new transfer discards an older pending receipt")
    func newTransferDiscardsOlderPendingReceipt() async throws {
        let context = makeContext()
        let drag = NectoPluginSidebarDrag()
        let provider = drag.provider(for: source, in: context)
        var moved = false
        try #require(drag.receive([provider], context: context, currentContext: { context }) { _ in
            moved = true
        })

        _ = drag.provider(for: source, in: context)
        // A superseded receipt is discarded without a completion callback.
        try await Task.sleep(for: .seconds(1))
        #expect(!moved)
        #expect(drag.acceptsDrop(in: context))
    }

    private func makeContext(bundle: String = "preview-a") -> NectoPluginSidebarDrag.Context {
        .init(
            target: .init(deviceID: "preview", appBundleID: bundle),
            device: .init(layout: .init(), activePluginIDs: ["a"]),
            desktop: .init(layout: .init(), activePluginIDs: [])
        )
    }

    private func receivedValue<Value: Sendable>(
        from receipt: (stream: AsyncStream<Value>, continuation: AsyncStream<Value>.Continuation)
    ) async throws -> Value {
        let timeout = Task {
            try await Task.sleep(for: .seconds(3))
            receipt.continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = receipt.stream.makeAsyncIterator()
        return try #require(await iterator.next(), "The drop did not finish before the timeout")
    }

    private func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }
}
