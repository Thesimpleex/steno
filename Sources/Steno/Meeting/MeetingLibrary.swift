import Foundation

/// Die Meetings in der Ablage, neueste zuerst. Es gibt kein eigenes Archiv: Die Ordner sind die Liste.
final class MeetingLibrary: ObservableObject {
    struct Item: Identifiable, Equatable {
        let folder: URL
        let info: MeetingInfo
        var id: URL { folder }
    }

    @Published private(set) var items: [Item] = []

    /// Für Vorschaubilder und Tests: eine Liste, die ohne Ablage auskommt.
    init(items: [Item] = []) {
        self.items = items
    }

    /// Liest die Ablage neu ein.
    func reload() {}

    func file(of item: Item) -> MeetingFile? { MeetingStore.read(item.folder) }

    /// Treffer in Titel, Teilnehmern und Protokolltext. Leere Suche: alle.
    func items(matching query: String) -> [Item] { items }

    /// Legt den Meeting-Ordner in den Papierkorb.
    func trash(_ item: Item) {}
}
