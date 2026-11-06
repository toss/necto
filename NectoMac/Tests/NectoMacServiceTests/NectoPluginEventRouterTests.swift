//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoModel
import Testing

@testable import NectoMacService

@Suite("Plugin event routing")
struct NectoPluginEventRouterTests {
    @Test("full-event handlers preserve sender identity and target")
    func routesFullEnvelope() async throws {
        let router = NectoPluginEventRouter()
        let receiver = RoutedEvents()
        await router.on(channel: "necto.usage") { event, target in
            await receiver.append(event, from: target)
        }
        let first = NectoTarget(deviceID: "device", appBundleID: "first.app")
        let second = NectoTarget(deviceID: "device", appBundleID: "second.app")
        let event = NectoPluginEvent(pluginID: "app-logger", channel: "necto.usage", payload: ["eventName": "started"])
        await router.route(event, from: first)
        await router.route(event, from: second)
        await router.route(NectoPluginEvent(pluginID: "ignored", channel: "unknown", payload: .null), from: first)
        let received = await receiver.events
        #expect(received.map(\.0) == [event, event])
        #expect(received.map(\.1) == [first, second])
    }

    @Test("a new handler replaces the previous handler on the same channel")
    func replacesHandler() async throws {
        let router = NectoPluginEventRouter()
        let old = RoutedEvents()
        let replacement = RoutedEvents()
        await router.on(channel: "records") { event, target in
            await old.append(event, from: target)
        }
        await router.on(channel: "records") { event, target in
            await replacement.append(event, from: target)
        }
        let target = NectoTarget(deviceID: "device", appBundleID: "app")
        let event = NectoPluginEvent(pluginID: "app-logger", channel: "records", payload: ["count": 1])
        await router.route(event, from: target)
        #expect(await old.events.isEmpty)
        let received = await replacement.events
        #expect(received.count == 1)
        #expect(received.first?.0 == event)
        #expect(received.first?.1 == target)
        await router.on(channel: "records") { event, target in
            await old.append(event, from: target)
        }
        await router.route(event, from: target)
        #expect(await old.events.count == 1)
        #expect(await replacement.events.count == 1)
    }
}

private actor RoutedEvents {
    private(set) var events: [(NectoPluginEvent, NectoTarget)] = []

    func append(_ event: NectoPluginEvent, from target: NectoTarget) {
        events.append((event, target))
    }
}
