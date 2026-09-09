//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoMacService
import Foundation
import SwiftUI

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
                .fill(colour)
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

    private var colour: Color {
        switch entry.severity {
        case .info: NectoTheme.textTertiary
        case .warning: NectoTheme.warning
        case .failure: NectoTheme.danger
        }
    }
}
