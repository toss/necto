//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

/// Generates traffic for the network plugin to show.
///
/// Requests are real, so the plugin displays real timings, bodies and failures rather
/// than fixtures. They cover the shapes a REST client actually produces — every
/// method, a request body, a large response, a slow one, a 404, and a transport
/// failure — because a plugin that only ever sees one healthy GET is a plugin whose
/// layout has not been tested.
struct NetworkView: View {
    private struct Call: Identifiable {
        let id = UUID()
        let title: String
        let method: String
        let url: String
        var body: [String: String]?
    }

    private struct Attempt: Identifiable {
        let id = UUID()
        let title: String
        let method: String
        let outcome: String
        let milliseconds: Int
    }

    /// Answered by `LocalAPI` inside this app.
    ///
    /// Nothing here needs the internet: the plugin captures a request where
    /// `URLProtocol` sees it, long before it would reach a network. Serving the demo
    /// locally means it behaves the same offline, on a corporate connection that
    /// inspects TLS, and on a device that has never been online.
    private static var api: String { LocalAPI.shared.origin }

    private static var calls: [Call] {
        [
            Call(title: "List posts", method: "GET", url: "\(api)/posts"),
            Call(title: "Get one post", method: "GET", url: "\(api)/posts/1"),
            Call(
                title: "Create a post",
                method: "POST",
                url: "\(api)/posts",
                body: ["title": "Necto", "body": "Sent from Necto Example", "userId": "1"]
            ),
            Call(
                title: "Update a post",
                method: "PATCH",
                url: "\(api)/posts/1",
                body: ["title": "Edited by Necto"]
            ),
            Call(title: "End the session", method: "DELETE", url: "\(api)/session"),
            // Past the capture limit, so the plugin has to truncate the body.
            Call(title: "Large response", method: "GET", url: "\(api)/large"),
            // Answers after two seconds, so a slow row sits beside the fast ones.
            Call(title: "Slow response", method: "GET", url: "\(api)/slow"),
            Call(title: "Not found", method: "GET", url: "\(api)/posts/999"),
            Call(title: "Server error", method: "GET", url: "\(api)/error"),
            // The one request that genuinely leaves the app, so a transport failure is
            // shown as well as an HTTP one.
            Call(title: "Unresolvable host", method: "GET", url: "https://necto-example.invalid/missing"),
        ]
    }

    @State private var attempts: [Attempt] = []
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Run every request") {
                        Task { await runAll() }
                    }
                    .fontWeight(.medium)
                } footer: {
                    Text("Open the Network plugin in Necto to watch these arrive.")
                }
                .disabled(isRunning)

                Section("One at a time") {
                    ForEach(Self.calls) { call in
                        Button {
                            Task { await send(call) }
                        } label: {
                            LabeledContent(call.title) {
                                Text(call.method)
                                    .monospaced()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .disabled(isRunning)

                if !attempts.isEmpty {
                    Section("Recent") {
                        ForEach(attempts) { attempt in
                            LabeledContent("\(attempt.method) \(attempt.title)") {
                                Text("\(attempt.outcome) · \(attempt.milliseconds)ms")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Network")
        }
    }

    /// Sequential rather than concurrent, so the plugin's list reads in the order the
    /// buttons are listed instead of whatever finishes first.
    private func runAll() async {
        for call in Self.calls {
            await send(call)
        }
    }

    private func send(_ call: Call) async {
        isRunning = true
        defer { isRunning = false }

        let started = Date()
        var outcome = "failed"

        if let url = URL(string: call.url) {
            var request = URLRequest(url: url)
            request.httpMethod = call.method

            if let body = call.body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                outcome = String((response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                // The reason matters: a blocked host and a refused connection look the
                // same in a list that only says "failed".
                outcome = (error as? URLError).map { "\($0.code.rawValue)" } ?? "failed"
            }
        }

        attempts.insert(
            Attempt(
                title: call.title,
                method: call.method,
                outcome: outcome,
                milliseconds: Int(Date().timeIntervalSince(started) * 1000)
            ),
            at: 0
        )
    }
}
