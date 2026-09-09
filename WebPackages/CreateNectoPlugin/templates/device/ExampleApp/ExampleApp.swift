//
// Copyright (c) 2026 Viva Republica, Inc.
//

import NectoSDK
import SwiftUI
import __PLUGIN_MODULE__

@main
struct ExampleApp: App {
    init() {
        NectoSDK.register(__PLUGIN_MODULE__())
        NectoSDK.start()
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "cable.connector")
                    .font(.largeTitle)
                Text("__DISPLAY_NAME__")
                    .font(.headline)
                Text("Run Necto on your Mac to open the plugin panel.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
