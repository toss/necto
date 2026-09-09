//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Testing

@testable import NectoModel

@Test func currentVersionIsOne() {
    #expect(NectoProtocol.currentVersion == 1)
}

@Test func rejectsOtherProtocolVersions() {
    #expect(NectoProtocol.isSupported(version: 1))
    #expect(!NectoProtocol.isSupported(version: 2))
    #expect(!NectoProtocol.isSupported(version: 0))
}
