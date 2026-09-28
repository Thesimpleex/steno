import Foundation

enum Paths {
    /// `STENO_DATA=/pfad` lenkt alles in einen anderen Ordner – zum Testen eines frischen Starts.
    static let support: URL = {
        let dir = ProcessInfo.processInfo.environment["STENO_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? applicationSupport.appendingPathComponent("Steno", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let models: URL = {
        let dir = support.appendingPathComponent("Modelle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let history = support.appendingPathComponent("verlauf.json")
    static let dictionary = support.appendingPathComponent("woerterbuch.json")
    /// Silero-Sprachdetektor (ggml-org/whisper-vad): schneidet Stille ab, verhindert erfundene Sätze.
    static let voiceDetector = Bundle.main.path(forResource: "ggml-silero-v5.1.2", ofType: "bin")

    private static let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// nil = noch nicht gewählt (dann gilt der Vorschlag aus der Systemsprache).
    static var language: String? {
        get { defaults.string(forKey: "sprache") }
        set { defaults.set(newValue, forKey: "sprache") }
    }

    static var pauseMusic: Bool {
        get { defaults.object(forKey: "musikPausieren") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "musikPausieren") }
    }

    static var sounds: Bool {
        get { defaults.object(forKey: "toene") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "toene") }
    }

    /// Aus: Text nur in die Zwischenablage und an der Notch zeigen, nie selbst einfügen.
    static var autoInsert: Bool {
        get { defaults.object(forKey: "einfuegen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "einfuegen") }
    }

    static var overlayStyle: OverlayStyle {
        get { defaults.string(forKey: "anzeige").flatMap(OverlayStyle.init(rawValue:)) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "anzeige") }
    }

    static var hotKey: HotKey {
        get { defaults.string(forKey: "diktierTaste").flatMap(HotKey.init(rawValue:)) ?? .leftOption }
        set { defaults.set(newValue.rawValue, forKey: "diktierTaste") }
    }

    /// 0 = Verlauf nicht speichern.
    static var historyDays: Int {
        get { defaults.object(forKey: "verlaufTage") as? Int ?? 7 }
        set { defaults.set(newValue, forKey: "verlaufTage") }
    }

    /// Dateiname eines Katalog-Modells oder voller Pfad eines eigenen Modells.
    static var model: String? {
        get { defaults.string(forKey: "modell") }
        set { defaults.set(newValue, forKey: "modell") }
    }
}

// MARK: - Verlauf

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var text: String
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry]  // neueste zuerst
    @Published var retentionDays = Settings.historyDays {
        didSet {
            Settings.historyDays = retentionDays
            expire()
            if retentionDays == 0 { onCleared?() }
        }
    }
    /// Verlauf gelöscht – dann soll auch sonst nichts mehr vom letzten Diktat übrig sein.
    var onCleared: (() -> Void)?

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = readJSON(Paths.history) { try decoder.decode([HistoryEntry].self, from: $0) } ?? []
        expire()
    }

    func add(_ text: String) {
        guard retentionDays > 0 else { return }
        entries.insert(HistoryEntry(date: .now, text: text), at: 0)
        dropExpired()
        save()
    }

    func delete(_ entry: HistoryEntry) {
        let wasLatest = entries.first?.id == entry.id
        entries.removeAll { $0.id == entry.id }
        save()
        if wasLatest { onCleared?() }
    }

    func deleteAll() {
        entries.removeAll()
        save()
        onCleared?()
    }

    func expire() {
        if dropExpired() { save() }
    }

    @discardableResult
    private func dropExpired() -> Bool {
        let cutoff = Date.now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let count = entries.count
        entries.removeAll { $0.date < cutoff }
        return entries.count != count
    }

    private func save() {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: Paths.history)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: Paths.history, options: .atomic)
    }
}

// MARK: - Wörterbuch

struct Replacement: Codable, Identifiable {
    var id = UUID()
    var von: String
    var zu: String

    private enum CodingKeys: String, CodingKey { case von, zu }
}

/// Unveränderliche Kopie des Wörterbuchs für die Arbeit im Hintergrund.
struct Vocabulary {
    var words: [String]
    var replacements: [Replacement]

    var whisperPrompt: String { words.isEmpty ? "" : words.joined(separator: ", ") + "." }
}

final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()

    @Published var woerter: [String] { didSet { save() } }
    @Published var ersetzungen: [Replacement] { didSet { save() } }

    private struct File: Codable {
        var woerter: [String]
        var ersetzungen: [Replacement]
    }

    private init() {
        let file = readJSON(Paths.dictionary) { try JSONDecoder().decode(File.self, from: $0) }
            ?? File(woerter: [], ersetzungen: [])
        woerter = file.woerter
        ersetzungen = file.ersetzungen
    }

    var vocabulary: Vocabulary { Vocabulary(words: woerter, replacements: ersetzungen) }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(File(woerter: woerter, ersetzungen: ersetzungen)).write(to: Paths.dictionary, options: .atomic)
    }
}

enum DataFiles {
    /// Name der zuletzt zur Seite gelegten, beschädigten Datei – wird beim Start einmal gemeldet.
    static var lastBackup: String?
}

/// Liest eine JSON-Datei. Ist sie beschädigt, wird sie zur Seite gelegt statt beim nächsten Speichern überschrieben.
private func readJSON<T>(_ url: URL, _ decode: (Data) throws -> T) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    do {
        return try decode(data)
    } catch {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingPathExtension().appendingPathExtension("defekt-\(stamp).json")
        if (try? FileManager.default.moveItem(at: url, to: backup)) != nil { DataFiles.lastBackup = backup.lastPathComponent }
        return nil
    }
}
