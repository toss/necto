//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI

/// The design tokens from `docs/design.md`, in SwiftUI form.
///
/// The same values live in `WebPackages/Bridge/theme.css`. `script/check-design-tokens.mjs`
/// compares both copies and the WebView override.
enum NectoTheme {
    // MARK: Colors

    static let background = adaptive(light: 0xFFFFFF, dark: 0x1C1C1B)
    static let sidebar = adaptive(light: 0xFCFCFC, dark: 0x161615)
    static let surface = adaptive(light: 0xFCFCFC, dark: 0x232322)
    static let hover = adaptive(light: 0xF6F7F6, dark: 0x232322)
    static let selected = adaptive(light: 0xEFF1F0, dark: 0x2B2B29)
    static let border = adaptive(light: 0xE5E5E5, dark: 0x333331)
    static let borderStrong = adaptive(light: 0xCFCFC9, dark: 0x43433F)
    static let text = adaptive(light: 0x141413, dark: 0xEEEEEA)
    static let textSecondary = adaptive(light: 0x4F4F4B, dark: 0xB4B4AD)
    static let textTertiary = adaptive(light: 0x666662, dark: 0x94948E)

    /// Selection and focus are ink, not colour. In a debugging tool a coloured thing
    /// should mean something happened, and nothing else.
    static let accent = adaptive(light: 0x141413, dark: 0xEEEEEA)
    /// Necto's own colour. Identity only: the app icon and the brand line.
    static let brand = adaptive(light: 0xAC5635, dark: 0xD1886B)

    static let success = adaptive(light: 0x1A6F3E, dark: 0x4AC26B)
    static let warning = adaptive(light: 0x8A5A00, dark: 0xE0A52E)
    static let danger = adaptive(light: 0xB3261E, dark: 0xFF6B60)
    static let info = adaptive(light: 0x2B5FD9, dark: 0x6CB0FF)

    // MARK: Shape

    static let radiusControl: CGFloat = 4
    static let radiusPanel: CGFloat = 10

    // MARK: Metrics

    /// One density across the window. Two densities read as two applications.
    static let rowHeight: CGFloat = 26
    static let buttonHeight: CGFloat = 24
    static let toolbarHeight: CGFloat = 38

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

/// Text sizes scale from a single user preference, so one setting moves the whole app.
///
/// Stored as the body size in points rather than as a named step, because the useful
/// answer to "how big is the text" is a number you can type, and a debugging tool is
/// read for hours at a stretch.
enum NectoTextSize {
    static let key = "textSizePoints"
    static let base: CGFloat = Font.NectoRole.body.size
    static let range: ClosedRange<CGFloat> = 9 ... 24
    static let step: CGFloat = 1

    /// Every other size is derived from this one, so the ladder keeps its proportions.
    static func scale(forPoints points: CGFloat) -> CGFloat {
        clamp(points) / base
    }

    static func clamp(_ points: CGFloat) -> CGFloat {
        min(max(points.rounded(), range.lowerBound), range.upperBound)
    }
}

/// Font families shared by the native shell and every web plugin.
///
/// The stored values use CSS font-family syntax because a fallback stack is useful to
/// plugins. The shell takes the first installed family from the same stack.
enum NectoFontPreference {
    static let uiKey = "uiFontFamily"
    static let codeKey = "codeFontFamily"
    static let defaultUI = "-apple-system"
    static let defaultCode = "ui-monospace"

    static func value(for key: String, fallback: String) -> String {
        let stored = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return fallback }
        return stored
    }

    static func font(
        family: String,
        role: Font.NectoRole,
        scale: CGFloat,
        fallbackDesign: Font.Design
    ) -> Font {
        let size = role.size * scale
        for candidate in families(in: family) {
            switch candidate.lowercased() {
            case "-apple-system", "system-ui", "sans-serif":
                return .system(size: size, weight: role.weight, design: .default)
            case "ui-monospace", "monospace":
                return .system(size: size, weight: role.weight, design: .monospaced)
            default:
                if let installed = NSFontManager.shared.availableFontFamilies.first(where: {
                    $0.caseInsensitiveCompare(candidate) == .orderedSame
                }) {
                    return .custom(installed, fixedSize: size).weight(role.weight)
                }
            }
        }
        return .system(size: size, weight: role.weight, design: fallbackDesign)
    }

    private static func families(in stack: String) -> [String] {
        stack.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
}

extension Font {
    enum NectoRole {
        case title, body, label, caption

        var size: CGFloat {
            switch self {
            case .title: 17
            case .body: 13
            case .label: 12
            case .caption: 11
            }
        }

        var weight: Font.Weight {
            switch self {
            case .title: .semibold
            case .body: .regular
            case .label: .medium
            case .caption: .regular
            }
        }
    }

    static func necto(
        _ role: NectoRole,
        scale: CGFloat = 1,
        mono: Bool = false,
        family: String? = nil
    ) -> Font {
        let key = mono ? NectoFontPreference.codeKey : NectoFontPreference.uiKey
        let fallback = mono ? NectoFontPreference.defaultCode : NectoFontPreference.defaultUI
        return NectoFontPreference.font(
            family: family ?? NectoFontPreference.value(for: key, fallback: fallback),
            role: role,
            scale: scale,
            fallbackDesign: mono ? .monospaced : .default
        )
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
