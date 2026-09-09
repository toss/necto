//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

enum NectoLanguage: String, CaseIterable, Identifiable {
    static let key = "appLanguage"

    case system
    case english
    case korean

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .korean: Locale(identifier: "ko")
        }
    }

    var label: String {
        switch self {
        case .system: NectoL10n.text("System")
        case .english: "English"
        case .korean: "한국어"
        }
    }
}

enum NectoL10n {
    static var language: NectoLanguage {
        let stored = UserDefaults.standard.string(forKey: NectoLanguage.key)
        return NectoLanguage(rawValue: stored ?? "") ?? .system
    }

    static func text(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: formattingLocale, arguments: arguments)
    }

    static var languageCode: String {
        switch language {
        case .system:
            Bundle.main.preferredLocalizations.first(where: { $0 == "en" || $0 == "ko" }) ?? "en"
        case .english: "en"
        case .korean: "ko"
        }
    }

    private static var localizedBundle: Bundle {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    private static var formattingLocale: Locale {
        Locale(identifier: languageCode)
    }
}
