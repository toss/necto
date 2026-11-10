//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import NectoMacService
import Foundation
import SwiftUI

/// A detail of the exporter settings, with a subscription only while it is open.
struct SettingsExporterDiagnostics: View {
    let log: NectoDiagnosticsLog
    let scale: CGFloat
    let back: () -> Void
    @State private var entries: [NectoDiagnosticsLog.Entry] = []
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                Label(NectoL10n.text("Event Exporter"), systemImage: "chevron.left")
                    .font(.necto(.label, scale: scale))
                    .foregroundStyle(NectoTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.exporter-diagnostics.back")
            .padding(.bottom, 16)

            HStack(alignment: .firstTextBaseline) {
                NectoSectionTitle(NectoL10n.text("Exporter diagnostics"), scale: scale, isFirst: true)
                Spacer(minLength: 12)
                Button(didCopy ? NectoL10n.text("Copied") : NectoL10n.text("Copy all")) { copyLog() }
                    .buttonStyle(NectoButtonStyle(scale: scale, quiet: true))
                    .disabled(entries.isEmpty)
            }

            if entries.isEmpty {
                NectoEmpty(
                    title: NectoL10n.text("Nothing logged yet"),
                    detail: NectoL10n.text("Exporter diagnostics appear here."),
                    scale: scale
                )
                .frame(height: 120)
            } else {
                ForEach(entries) { entry in
                    LogRow(entry: entry, scale: scale)
                }
            }
        }
        .task {
            for await entries in await log.updates(source: .exporter) {
                guard !Task.isCancelled else { return }
                self.entries = entries
            }
        }
    }

    private func copyLog() {
        Task {
            let transcript = await log.transcript(source: .exporter)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            didCopy = true
            try? await Task.sleep(for: .seconds(1.4))
            didCopy = false
        }
    }
}

/// One line: when, how bad, where from, and what happened.
struct LogRow: View {
    let entry: NectoDiagnosticsLog.Entry
    let scale: CGFloat

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed rather than localised, for the same reason the network log's is: a
        // timestamp in a log is read by position.
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.clock.string(from: entry.at))
                .foregroundStyle(NectoTheme.textTertiary)

            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            Text(entry.source.rawValue)
                .foregroundStyle(NectoTheme.textTertiary)
                .lineLimit(1)
                // Wide enough for 'connection', the longest of them.
                .frame(width: 92 * scale, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .foregroundStyle(NectoTheme.text)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.necto(.caption, scale: scale))
                        .foregroundStyle(NectoTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .font(.necto(.label, scale: scale))
        .textSelection(.enabled)
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(NectoTheme.border).frame(height: 1)
        }
    }

    private var color: Color {
        switch entry.severity {
        case .info: NectoTheme.textTertiary
        case .warning: NectoTheme.warning
        case .failure: NectoTheme.danger
        }
    }
}
