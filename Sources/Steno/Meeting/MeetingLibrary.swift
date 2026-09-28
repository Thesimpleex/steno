import Foundation

/// Die Meetings in der Ablage, neueste zuerst. Es gibt kein eigenes Archiv: Die Ordner sind die Liste.
final class MeetingLibrary: ObservableObject {
    struct Item: Identifiable, Equatable {
        let folder: URL
        let info: MeetingInfo
        var id: URL { folder }
    }

    @Published private(set) var items: [Item] = []

    /// Bringt einen Ordner in den Papierkorb; Tests ersetzen das, damit der echte Papierkorb leer bleibt.
    var trashFolder: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Protokolltexte für die Suche mit dem Änderungsdatum, zu dem sie gelesen wurden. Beim Neuladen wird nur neu
    /// gelesen, was sich geändert hat; die Suche selbst liest nichts von der Platte.
    private var texts: [URL: (modified: Date, text: String)] = [:]
    /// Lesen und Parsen läuft hier statt auf dem Main-Thread: Bei vielen Meetings würde die Oberfläche sonst hängen.
    private let queue = DispatchQueue(label: "steno.meetings.library", qos: .userInitiated)
    /// Nur das Ergebnis des zuletzt angestoßenen Ladens gilt; ältere, später fertige würden sonst Veraltetes zeigen.
    private var generation = 0

    /// Liest die Ablage im Hintergrund neu ein und ruft `done` auf dem Main-Thread, sobald die Liste steht – nur, wenn
    /// bis dahin kein neueres Laden angestoßen wurde.
    /// Ordner ohne lesbare meeting.json gehören nicht dazu.
    func reload(done: @escaping () -> Void = {}) {
        generation += 1
        let generation = generation, root = MeetingStore.root, cached = texts
        queue.async { [weak self] in
            let (items, texts) = MeetingLibrary.load(root, cached: cached)
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                self.items = items
                self.texts = texts
                done()
            }
        }
    }

    private static func load(_ root: URL, cached: [URL: (modified: Date, text: String)])
        -> ([Item], [URL: (modified: Date, text: String)]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let items = names
            .compactMap { name -> Item? in
                let folder = root.appendingPathComponent(name, isDirectory: true)
                return MeetingStore.readInfo(folder).map { Item(folder: folder, info: $0) }
            }
            .sorted { $0.info.startedAt > $1.info.startedAt }
        var texts: [URL: (modified: Date, text: String)] = [:]
        for item in items {
            let url = item.folder.appendingPathComponent(MeetingFile.markdownName)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if let known = cached[item.folder], known.modified == modified {
                texts[item.folder] = known
            } else {
                texts[item.folder] = (modified, (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
        }
        return (items, texts)
    }

    /// Treffer in Titel, Teilnehmern und Protokolltext, ohne Rücksicht auf Groß-/Kleinschreibung und Akzente. Leere Suche: alle.
    func items(matching query: String) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.info.title.localizedStandardContains(query) || $0.info.participants.localizedStandardContains(query)
                || (texts[$0.folder]?.text ?? "").localizedStandardContains(query)
        }
    }

    /// Legt den Meeting-Ordner in den Papierkorb; false, wenn das nicht ging – dann bleibt das Meeting in der Liste.
    @discardableResult
    func trash(_ item: Item) -> Bool {
        guard (try? trashFolder(item.folder)) != nil else { return false }
        items.removeAll { $0.id == item.id }
        texts[item.folder] = nil
        // Neu laden: Ein Laden, das den Ordner vorher noch gesehen hat, gilt damit nicht mehr und bringt ihn nicht zurück.
        reload()
        return true
    }
}
