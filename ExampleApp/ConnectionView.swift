//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoSDK
import SwiftUI

/// Shows what the SDK is doing, so a failed connection is visible on the device
/// rather than only in the Mac app.
struct ConnectionView: View {
    @State private var status = NectoSDK.status

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Necto") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(indicator)
                                .frame(width: 8, height: 8)
                            Text(describe(status))
                        }
                    }
                    LabeledContent("Protocol", value: "v\(NectoSDK.protocolVersion)")
                }

                Section {
                    Button("Stop listening") { NectoSDK.stop() }
                    Button("Start listening") { ExampleApp.startNecto() }
                } footer: {
                    Text("Necto reaches this app over USB on a device, and over loopback in a simulator.")
                }
            }
            .navigationTitle("Connection")
            .onReceive(poll) { _ in status = NectoSDK.status }
        }
    }

    private var indicator: Color {
        switch status {
        case .connected: .green
        case .listening: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }

    private func describe(_ status: NectoSDK.Status) -> String {
        switch status {
        case .stopped: "Stopped"
        case let .listening(port): "Listening on \(port)"
        case let .connected(appBundleID): "Connected as \(appBundleID)"
        case let .failed(reason): reason
        }
    }
}
