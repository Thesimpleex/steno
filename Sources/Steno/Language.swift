import Foundation

/// App-Texte: Schlüssel ist der deutsche Text, Übersetzungen liegen in en.lproj / fr.lproj.
/// Die App-Sprache folgt der Systemsprache des Macs.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: Localization.bundle, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: Localization.bundle, comment: ""), arguments: arguments)
}

enum Localization {
    /// Normalerweise die App selbst; die Entwickler-Werkzeuge stellen hier für Bildschirmfotos eine Sprache ein.
    static var bundle = Bundle.main
}

/// Die Sprache, in der diktiert wird – unabhängig von der Sprache der App.
enum SpeechLanguage: String, CaseIterable, Identifiable {
    case german = "de"
    case swissGerman = "de-CH"
    case english = "en"
    case french = "fr"
    case italian = "it"
    case spanish = "es"
    case automatic = "auto"

    var id: String { rawValue }

    /// Jede Sprache in ihrem eigenen Namen.
    var name: String {
        switch self {
        case .german: return "Deutsch"
        case .swissGerman: return "Schweizerdeutsch"
        case .english: return "English"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        case .automatic: return L("Mehrere – automatisch erkennen")
        }
    }

    var flag: String {
        switch self {
        case .german: return "🇩🇪"
        case .swissGerman: return "🇨🇭"
        case .english: return "🇬🇧"
        case .french: return "🇫🇷"
        case .italian: return "🇮🇹"
        case .spanish: return "🇪🇸"
        case .automatic: return "🌍"
        }
    }

    var note: String? {
        switch self {
        case .swissGerman: return L("Wird auf Hochdeutsch geschrieben, mit „ss“ statt „ß“.")
        case .automatic: return L("Erkennt die Sprache bei jedem Diktat neu – etwas langsamer.")
        default: return nil
        }
    }

    /// Code für Whisper. Schweizerdeutsch gibt es dort nicht als Schriftsprache: es wird Hochdeutsch.
    var whisperCode: String {
        switch self {
        case .swissGerman: return "de"
        default: return rawValue
        }
    }

    /// Kandidaten für „automatisch“ – nur diese, damit kurze Schnipsel nicht als Walisisch enden.
    static let detectable = ["de", "en", "fr", "it", "es"]

    static var current: SpeechLanguage {
        get { SpeechLanguage(rawValue: Settings.language ?? "") ?? suggested }
        set { Settings.language = newValue.rawValue }
    }

    /// Vorschlag aus den Systemeinstellungen des Macs.
    static var suggested: SpeechLanguage {
        let locale = Locale.current
        switch locale.language.languageCode?.identifier {
        case "de": return locale.region?.identifier == "CH" ? .swissGerman : .german
        case "en": return .english
        case "fr": return .french
        case "it": return .italian
        case "es": return .spanish
        default: return .automatic
        }
    }
}
