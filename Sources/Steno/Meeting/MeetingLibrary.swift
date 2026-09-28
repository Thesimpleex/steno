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

    /// Protokolltexte für die Suche: gelesen wird erst beim Suchen, und nur neu, wenn sich die Datei geändert hat.
    private var texts: [URL: (modified: Date, text: String)] = [:]

    /// Für Vorschaubilder und Tests: eine Liste, die ohne Ablage auskommt.
    init(items: [Item] = []) {
        self.items = items
    }

    /// Liest die Ablage neu ein. Ordner ohne lesbare meeting.json gehören nicht dazu.
    func reload() {
        let root = MeetingStore.root
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        items = names
            .compactMap { name -> Item? in
                let folder = root.appendingPathComponent(name, isDirectory: true)
                return MeetingStore.read(folder).map { Item(folder: folder, info: $0.info) }
            }
            .sorted { $0.info.startedAt > $1.info.startedAt }
    }

    func file(of item: Item) -> MeetingFile? { MeetingStore.read(item.folder) }

    /// Treffer in Titel, Teilnehmern und Protokolltext, ohne Rücksicht auf Groß-/Kleinschreibung und Akzente. Leere Suche: alle.
    func items(matching query: String) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.info.title.localizedStandardContains(query) || $0.info.participants.localizedStandardContains(query)
                || protocolText(of: $0).localizedStandardContains(query)
        }
    }

    /// Legt den Meeting-Ordner in den Papierkorb.
    func trash(_ item: Item) {
        guard (try? trashFolder(item.folder)) != nil else { return }
        items.removeAll { $0.id == item.id }
    }

    private func protocolText(of item: Item) -> String {
        let url = item.folder.appendingPathComponent(MeetingFile.markdownName)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "" }
        if let cached = texts[item.folder], cached.modified == modified { return cached.text }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        texts[item.folder] = (modified, text)
        return text
    }
}
