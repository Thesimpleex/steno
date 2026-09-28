import AppKit

/// Legt Meetings als Ordner ab: meeting.json, Protokoll.md und bilder/.
enum MeetingStore {
    /// Für Tests und Prüfbilder: ersetzt die Ablage aus den Einstellungen.
    static var rootOverride: URL?

    static var root: URL { rootOverride ?? URL(fileURLWithPath: Settings.meetingFolder, isDirectory: true) }

    /// Legt den Ordner „2026-09-28 14-30 Titel“ in der Ablage an.
    static func makeFolder(for info: MeetingInfo) throws -> URL {
        let files = FileManager.default
        let parent = root
        let name = folderName(for: info)
        do {
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            var folder = parent.appendingPathComponent(name, isDirectory: true)
            var number = 2
            while files.fileExists(atPath: folder.path) {
                folder = parent.appendingPathComponent("\(name) \(number)", isDirectory: true)
                number += 1
            }
            try files.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        } catch {
            throw MeetingError.folderUnavailable(parent.lastPathComponent)
        }
    }

    /// Schreibt meeting.json und Protokoll.md, jeweils atomar. Fehlt der Ordner – verschoben oder von iCloud ausgelagert –,
    /// wird er neu angelegt; sonst schlüge jedes weitere Speichern fehl.
    static func write(_ file: MeetingFile, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(file).write(to: folder.appendingPathComponent(MeetingFile.fileName), options: .atomic)
            try Data(MeetingMarkdown.render(file).utf8).write(to: folder.appendingPathComponent(MeetingFile.markdownName), options: .atomic)
        } catch {
            throw MeetingError.folderUnavailable(folder.lastPathComponent)
        }
    }

    /// Nil bei jedem Fehler: Eine beschädigte oder von Hand bearbeitete Datei darf die App nie zum Absturz bringen.
    static func read(_ folder: URL) -> MeetingFile? { decode(MeetingFile.self, in: folder) }

    /// Nur die Angaben zum Meeting: Mehr braucht die Liste nicht, und lange Mitschriften würden sie aufhalten.
    static func readInfo(_ folder: URL) -> MeetingInfo? { decode(Head.self, in: folder)?.info }

    /// meeting.json ohne die Einträge.
    private struct Head: Decodable {
        var info: MeetingInfo
    }

    private static func decode<T: Decodable>(_ type: T.Type, in folder: URL) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(MeetingFile.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// Speichert das Bild als PNG im Bilderordner und liefert den Dateinamen.
    static func saveImage(_ image: NSImage, at offset: TimeInterval, in folder: URL) throws -> String {
        let failure = MeetingError.folderUnavailable(folder.lastPathComponent)
        // Über TIFF, damit ein Retina-Screenshot alle seine Bildpunkte behält und nicht auf Punktgröße schrumpft.
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw failure }
        let files = FileManager.default
        let images = folder.appendingPathComponent(MeetingFile.imageFolder, isDirectory: true)
        let base = MeetingMarkdown.timestamp(offset).replacingOccurrences(of: ":", with: "-")
        do {
            try files.createDirectory(at: images, withIntermediateDirectories: true)
            var name = base + ".png"
            var number = 2
            while files.fileExists(atPath: images.appendingPathComponent(name).path) {
                name = "\(base)-\(number).png"
                number += 1
            }
            try png.write(to: images.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            throw failure
        }
    }

    /// „2026-09-28 14-30 Titel“ in Ortszeit. `/`, `:` und `\` gehen in Dateinamen nicht und Zeilenumbrüche stören:
    /// Sie werden wie Leerzeichen behandelt.
    private static func folderName(for info: MeetingInfo) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let words = info.title.split { $0.isWhitespace || "/:\\".contains($0) }.joined(separator: " ")
        var title = String(words.prefix(60))
        // Dateinamen sind auf 255 Zeichen oder Bytes begrenzt, und manches Zeichen braucht vier Bytes.
        while title.utf8.count > 200 { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        return formatter.string(from: info.startedAt) + " " + (title.isEmpty ? "Meeting" : title)
    }
}
