import Foundation

/// Wer spricht: du selbst (Mikrofon) oder die anderen Teilnehmer (Ton des Macs).
enum Speaker: String, Codable {
    case you, others
}

/// Ein Eintrag der Zeitleiste. `offset` sind Sekunden seit Beginn der Aufnahme.
struct MeetingEntry: Identifiable, Codable, Equatable {
    enum Kind: Codable, Equatable {
        case speech(Speaker, String)
        case note(String)
        case task(String)
        /// Eine Stelle, die man später wiederfinden will – ohne Text.
        case mark
        /// Dateiname im Bilderordner des Meetings.
        case image(String)
    }

    var id = UUID()
    var offset: TimeInterval
    var kind: Kind
}

struct MeetingSources: OptionSet, Codable {
    let rawValue: Int
    static let microphone = MeetingSources(rawValue: 1)
    static let systemAudio = MeetingSources(rawValue: 2)
}

struct MeetingInfo: Codable, Equatable {
    var title: String
    var startedAt: Date
    /// Sekunden. Solange das Meeting läuft, die Dauer beim letzten Speichern.
    var duration: TimeInterval = 0
    var participants = ""
    /// Wie „Andere“ im Protokoll heißen, etwa „Herr Meier“. Leer heißt: „Andere“.
    var othersName = ""
    var sources: MeetingSources

    var othersLabel: String { othersName.isEmpty ? L("Andere") : othersName }
}

/// Inhalt von meeting.json. Maßgeblich ist diese Datei; Protokoll.md wird aus ihr gebaut.
struct MeetingFile: Codable, Equatable {
    var info: MeetingInfo
    var entries: [MeetingEntry]

    static let fileName = "meeting.json"
    static let markdownName = "Protokoll.md"
    static let imageFolder = "bilder"
}

/// Pegel 0…1 für die Anzeige.
struct MeetingLevels: Equatable {
    var you: Float = 0
    var others: Float = 0
}

enum MeetingError: LocalizedError {
    case noModel, alreadyRunning, noSource
    case microphoneDenied, systemAudioDenied
    /// Die Quelle startet nicht, und an der Freigabe liegt es nicht. Der Fehler von Core Audio sagt dem Nutzer nichts.
    case unavailable(Speaker)
    case folderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noModel: return L("Es ist noch kein Sprachmodell geladen.")
        case .alreadyRunning: return L("Es läuft schon ein Meeting.")
        case .noSource: return L("Mikrofon oder Mac-Ton muss eingeschaltet sein.")
        case .microphoneDenied: return L("Kein Mikrofonzugriff – bitte in den Systemeinstellungen erlauben.")
        case .systemAudioDenied: return L("Keine Freigabe für den Ton des Macs – bitte in den Systemeinstellungen erlauben.")
        case .unavailable(let speaker):
            return speaker == .you ? L("Das Mikrofon lässt sich nicht starten.") : L("Der Ton des Macs lässt sich nicht aufnehmen.")
        case .folderUnavailable(let name): return L("Der Ordner „%@“ lässt sich nicht beschreiben.", name)
        }
    }
}
