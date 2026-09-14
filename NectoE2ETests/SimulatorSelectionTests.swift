//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Testing

@Suite("Existing E2E simulator selection")
@MainActor
struct SimulatorSelectionTests {
    @Test("selects iPhone 17 Pro on the newest iOS regardless of boot state")
    func selectsNewestRuntime() {
        let selected = AppFixture.selectSimulator([
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [
                ["udid": "new", "name": "iPhone 17 Pro", "state": "Shutdown"],
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                ["udid": "old", "name": "iPhone 17 Pro", "state": "Booted"],
            ],
        ])
        #expect(selected?["udid"] as? String == "new")
    }

    @Test("does not fall back to another device")
    func requiresExactName() {
        #expect(AppFixture.selectSimulator([
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                ["name": "iPhone 17"], ["name": "iPhone 17 Pro Max"],
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-5": [["name": "iPhone 17 Pro"]],
        ]) == nil)
    }

    @Test("returns no device when none can be reused")
    func noAvailableDevice() {
        #expect(AppFixture.selectSimulator([:]) == nil)
    }
}
