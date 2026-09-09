//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import SwiftUI
import WebKit

/// Find inside whichever panel is on screen.
///
/// A panel is a web page, and ⌘F over a `WKWebView` does nothing — the system find bar
/// belongs to AppKit's text views. WebKit will search the page when asked, so the asking
/// lives here, once, in the host. The alternative is every panel growing a search box of
/// its own and each one behaving slightly differently.
@MainActor
final class NectoFindSession: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published private(set) var matchCount = 0
    @Published private(set) var selectedMatchIndex = 0
    @Published private(set) var focusRequest = 0
    @Published private(set) var scale: CGFloat = 1

    /// The view showing the current panel. Weak, and replaced whenever the selection
    /// changes: a panel that has gone away is not something to search.
    weak var webView: WKWebView?
    private weak var findBar: NSHostingView<NectoFindBar>?
    private var searchRevision = 0

    var isAvailable: Bool { webView != nil }

    func open() {
        guard let webView else { return }
        isPresented = true
        focusRequest += 1
        installFindBar(in: webView)
    }

    func close() {
        isPresented = false
        query = ""
        resetMatches()
        // An empty search is how WebKit is told to drop the highlights it drew.
        clearHighlights()
        findBar?.removeFromSuperview()
        findBar = nil
    }

    /// Called when the panel changes under the bar, so a stale query never highlights a
    /// page the person did not search.
    func attach(_ webView: WKWebView?, scale: CGFloat) {
        self.scale = scale
        if self.webView !== webView {
            clearHighlights()
            findBar?.removeFromSuperview()
            findBar = nil
            resetMatches()
        }
        self.webView = webView
        guard let webView else {
            isPresented = false
            return
        }
        if isPresented {
            installFindBar(in: webView)
            if !query.isEmpty { find(resetSelection: true) }
        }
    }

    func detach(_ webView: WKWebView?) {
        guard self.webView === webView else { return }
        close()
        self.webView = nil
    }

    func find(backwards: Bool = false, resetSelection: Bool = false) {
        searchRevision += 1
        let revision = searchRevision

        guard let webView, !query.isEmpty else {
            resetMatches()
            clearHighlights()
            return
        }

        let query = query

        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true

        Task { @MainActor [weak self] in
            let count = resetSelection
                ? await self?.countMatches(query, in: webView) ?? 0
                : self?.matchCount ?? 0
            let result = try? await webView.find(query, configuration: configuration)
            guard let self, revision == searchRevision, self.query == query else { return }

            guard result?.matchFound == true else {
                resetMatches()
                return
            }

            matchCount = max(count, 1)
            if resetSelection || selectedMatchIndex == 0 {
                selectedMatchIndex = backwards ? matchCount : 1
            } else if backwards {
                selectedMatchIndex = selectedMatchIndex == 1 ? matchCount : selectedMatchIndex - 1
            } else {
                selectedMatchIndex = selectedMatchIndex == matchCount ? 1 : selectedMatchIndex + 1
            }
        }
    }

    private func clearHighlights() {
        guard let webView else { return }
        Task { @MainActor in _ = try? await webView.find("", configuration: WKFindConfiguration()) }
    }

    private func installFindBar(in webView: WKWebView) {
        guard findBar == nil else { return }

        let findBar = NSHostingView(rootView: NectoFindBar(session: self))
        findBar.translatesAutoresizingMaskIntoConstraints = false
        webView.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: webView.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: webView.trailingAnchor, constant: -10),
        ])
        self.findBar = findBar
    }

    private func resetMatches() {
        matchCount = 0
        selectedMatchIndex = 0
    }

    private func countMatches(_ query: String, in webView: WKWebView) async -> Int {
        let script = """
        const needle = String(query).toLocaleLowerCase();
        const countIn = (value) => {
            const haystack = String(value).toLocaleLowerCase();
            let count = 0;
            let cursor = 0;
            while (needle.length > 0) {
                const index = haystack.indexOf(needle, cursor);
                if (index < 0) break;
                count += 1;
                cursor = index + needle.length;
            }
            return count;
        };

        let count = countIn(document.body?.innerText ?? "");
        for (const field of document.querySelectorAll('textarea, input:not([type="hidden"])')) {
            const style = getComputedStyle(field);
            if (style.display !== "none" && style.visibility !== "hidden") {
                count += countIn(field.value ?? "");
            }
        }
        return count;
        """
        let value = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["query": query],
            in: nil,
            contentWorld: .page
        )
        return (value as? NSNumber)?.intValue ?? 0
    }
}

/// The bar itself: a field, the two directions, and a way out.
///
/// The host installs this view as a child of the selected `WKWebView`, matching the
/// browser convention without requiring every plugin to implement search UI.
struct NectoFindBar: View {
    @ObservedObject var session: NectoFindSession

    @FocusState private var isFieldFocused: Bool

    private var scale: CGFloat { session.scale }

    var body: some View {
        HStack(spacing: 6) {
            TextField(NectoL10n.text("Find in panel"), text: $session.query)
                .textFieldStyle(.plain)
                .font(.necto(.body, scale: scale))
                .foregroundStyle(NectoTheme.text)
                .focused($isFieldFocused)
                .frame(width: 160 * scale)
                .onSubmit { session.find() }
                .onChange(of: session.query) { _, _ in session.find(resetSelection: true) }

            if !session.query.isEmpty {
                Text("\(session.selectedMatchIndex) / \(session.matchCount)")
                    .font(.necto(.caption, scale: scale))
                    .foregroundStyle(NectoTheme.textTertiary)
                    .monospacedDigit()
                    .fixedSize()
            }

            Button {
                session.find(backwards: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
            .disabled(session.matchCount == 0)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help(NectoL10n.text("Previous match"))

            Button {
                session.find()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
            .disabled(session.matchCount == 0)
            .keyboardShortcut(.downArrow, modifiers: .command)
            .help(NectoL10n.text("Next match"))

            Button {
                session.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
            .keyboardShortcut(.escape, modifiers: [])
            .help(NectoL10n.text("Close find"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(NectoTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: NectoTheme.radiusControl)
                .stroke(NectoTheme.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: NectoTheme.radiusControl))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .padding(10)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                isFieldFocused = true
            }
        }
        .onChange(of: session.focusRequest) { _, _ in
            isFieldFocused = true
        }
    }
}
