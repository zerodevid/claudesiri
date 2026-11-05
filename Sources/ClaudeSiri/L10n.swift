import Foundation

/// UI language: English or Indonesian. `uiLanguage` user default = "en", "id", or "system" (default),
/// where "system" follows the first preferred macOS language.
enum UILanguage: String, CaseIterable {
    case system, en, id

    static var current: UILanguage {
        UILanguage(rawValue: UserDefaults.standard.string(forKey: "uiLanguage") ?? "") ?? .system
    }

    /// True when the effective language is Indonesian.
    static var isIndonesian: Bool {
        switch current {
        case .id: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("id") ?? false
        }
    }

    var label: String {
        switch self {
        case .system: return tr("System", "Ikuti sistem")
        case .en: return "English"
        case .id: return "Bahasa Indonesia"
        }
    }
}

/// Pick the English or Indonesian variant of a UI string.
func tr(_ en: String, _ id: String) -> String { UILanguage.isIndonesian ? id : en }

/// Locale for formatting dates in the UI language.
var uiLocale: Locale { Locale(identifier: UILanguage.isIndonesian ? "id_ID" : "en_US") }
