//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoSDK
import SwiftUI

struct AboutView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Necto") {
                    LabeledContent("SDK", value: NectoSDK.version)
                    LabeledContent("Protocol", value: "v\(NectoSDK.protocolVersion)")
                }

                Section {
                    Text("This sample exists to verify a real connection. Keep it running and open Necto on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
        }
    }
}
