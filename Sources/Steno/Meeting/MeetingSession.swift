import AppKit

/// Ein Meeting, das gerade aufgenommen wird: Mikrofon und Ton des Macs werden in Abschnitte geschnitten,
/// mit Whisper umgewandelt und mit Zeitstempel in die Zeitleiste gelegt.
final class MeetingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        /// Die Quellen sind gestoppt, die letzten Abschnitte werden noch umgewandelt.
        case finishing
    }

    @Published private(set) var state = State.idle
    @Published private(set) var info = MeetingInfo(title: "", startedAt: .now, sources: [])
    @Published private(set) var entries: [MeetingEntry] = []
    @Published private(set) var levels = MeetingLevels()
    /// Eine Meldung für die Oberfläche, etwa wenn während des Meetings eine Quelle ausfällt.
    @Published private(set) var problem: String?

    /// Ordner des laufenden oder zuletzt beendeten Meetings.
    private(set) var folder: URL?
    /// Das geladene Sprachmodell; AppDelegate setzt es, so wie es `Dictation` bekommt.
    var transcriber: Transcriber?

    /// Beginnt ein Meeting. Wirft, wenn Modell, Freigabe oder Ordner fehlen.
    func start(title: String, sources: MeetingSources) throws {
        guard state == .idle else { throw MeetingError.alreadyRunning }
        info = MeetingInfo(title: title, startedAt: .now, sources: sources)
        entries = []
        state = .running
    }

    func stop() {
        info.duration = Date.now.timeIntervalSince(info.startedAt)
        state = .idle
    }

    /// Text leer: Markierung. Beginnt er mit „!“: Aufgabe. Sonst Notiz.
    func addNote(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: MeetingEntry.Kind
        if text.isEmpty {
            kind = .mark
        } else if text.hasPrefix("!") {
            kind = .task(text.dropFirst().trimmingCharacters(in: .whitespaces))
        } else {
            kind = .note(text)
        }
        entries.append(MeetingEntry(offset: Date.now.timeIntervalSince(info.startedAt), kind: kind))
    }

    /// Ein Screenshot aus der Zwischenablage; er wird als PNG im Bilderordner abgelegt.
    func addImage(_ image: NSImage) {}

    func remove(_ entry: MeetingEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    func rename(title: String) { info.title = title }
    func rename(others name: String) { info.othersName = name }
    func setParticipants(_ text: String) { info.participants = text }
}
