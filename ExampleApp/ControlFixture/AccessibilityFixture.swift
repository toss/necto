//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

struct AccessibilityFixture: View {
    @State private var taps = 0
    @State private var query = ""
    @State private var showSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Taps: \(taps)")
                        .accessibilityIdentifier("ax.status")
                    Button("Count tap") { taps += 1 }
                        .accessibilityIdentifier("ax.tap")
                    Button("Disabled button") { taps += 100 }
                        .disabled(true)
                    TextField("Query", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ax.query")
                    NavigationLink("Open detail") {
                        Text("Accessibility Detail")
                            .navigationTitle("Detail")
                    }
                    Button("Open sheet") { showSheet = true }
                    NavigationLink("Custom scroll action") { AccessibleScrollFixture() }
                    Text("Read-only text")
                    ForEach(1...80, id: \.self) { index in
                        Button("Row \(index)") { taps = index }
                            .accessibilityIdentifier("ax.row.\(index)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Accessibility")
            .sheet(isPresented: $showSheet) {
                Text("Accessibility Sheet")
            }
        }
    }
}

private struct AccessibleScrollFixture: View {
    @State private var page = 0
    @State private var requests = 0

    var body: some View {
        ScrollViewReader { proxy in
            VStack {
                Text("Scroll requests: \(requests), page: \(page)")
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(0..<80, id: \.self) { index in
                            Text("Accessible row \(index + 1)")
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Custom scroll area")
                .accessibilityScrollAction { edge in
                    requests += 1
                    page = min(7, max(0, page + (edge == .bottom || edge == .trailing ? 1 : -1)))
                    proxy.scrollTo(page * 10, anchor: .top)
                }
            }
        }
        .navigationTitle("Custom scroll")
    }
}
