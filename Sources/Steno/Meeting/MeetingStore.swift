import AppKit

/// Legt Meetings als Ordner ab: meeting.json, Protokoll.md und bilder/.
enum MeetingStore {
    /// Für Tests: ersetzt die Ablage aus den Einstellungen.
    static var rootOverride: URL?

    static var root: URL { rootOverride ?? URL(fileURLWithPath: Settings.meetingFolder, isDirectory: true) }

    /// Legt den Ordner „2026-09-28 14-30 Titel“ in der Ablage an.
    static func makeFolder(for info: MeetingInfo) throws -> URL {
        throw MeetingError.folderUnavailable(root.lastPathComponent)
    }

    /// Schreibt meeting.json und Protokoll.md, jeweils atomar.
    static func write(_ file: MeetingFile, to folder: URL) throws {}

    static func read(_ folder: URL) -> MeetingFile? { nil }

    /// Speichert das Bild als PNG im Bilderordner und liefert den Dateinamen.
    static func saveImage(_ image: NSImage, at offset: TimeInterval, in folder: URL) throws -> String { "" }

    static func markdown(for file: MeetingFile) -> String { "" }
}
