//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import Testing
@testable import NectoTransport

@Test("one key's approval cannot overlap or block another key", .timeLimit(.minutes(1)))
func keychainSigningSerialization() async throws {
    let queue = NectoKeychainSigningQueue()
    let events = AsyncStream<String>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal(); events.continuation.finish() }
    queue.submit(keyID: "shared-key") {
        events.continuation.yield("first-started")
        release.wait()
        events.continuation.yield("first-finished")
    }
    var iterator = events.stream.makeAsyncIterator()
    #expect(await iterator.next() == "first-started")
    queue.submit(keyID: "shared-key") { events.continuation.yield("second-started") }
    queue.submit(keyID: "other-key") { events.continuation.yield("other-started") }
    #expect(await iterator.next() == "other-started")
    release.signal()
    #expect(await iterator.next() == "first-finished")
    #expect(await iterator.next() == "second-started")
}
