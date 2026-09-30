//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Testing

@Suite("Existing E2E simulator selection")
@MainActor
struct SimulatorSelectionTests {
    @Test("selects the pinned runtime even when a newer simulator is booted")
    func selectsPinnedRuntime() {
        let selected = AppFixture.selectSimulator([
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                ["udid": "new", "name": "iPhone 17 Pro", "state": "Booted"],
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                ["udid": "pinned", "name": "iPhone 17 Pro", "state": "Shutdown"],
            ],
        ])
        #expect(selected?["udid"] as? String == "pinned")
    }

    @Test("does not fall back to another device")
    func requiresExactName() {
        #expect(AppFixture.selectSimulator([
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                ["name": "iPhone 17"], ["name": "iPhone 17 Pro Max"],
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-2": [["name": "iPhone 17 Pro"]],
        ]) == nil)
    }

    @Test("does not fall back to an unverified runtime when the pinned one is missing")
    func requiresPinnedRuntime() {
        #expect(AppFixture.selectSimulator([
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [["name": "iPhone 17 Pro"]],
        ]) == nil)
    }

    @Test("returns no device when none can be reused")
    func noAvailableDevice() {
        #expect(AppFixture.selectSimulator([:]) == nil)
    }
}
