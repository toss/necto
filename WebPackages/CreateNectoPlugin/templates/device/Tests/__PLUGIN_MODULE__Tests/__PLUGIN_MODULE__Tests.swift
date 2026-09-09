//
// Copyright (c) 2026 Viva Republica, Inc.
//

import Testing
@testable import __PLUGIN_MODULE__

@Test func carriesBuiltPanel() {
    #expect(__PLUGIN_MODULE__().panel != nil)
}
