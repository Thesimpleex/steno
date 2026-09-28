import XCTest
@testable import Steno

final class MeetingLibraryTests: XCTestCase {
    private let files = FileManager.default
    private var base: URL!
    private var root: URL!
    /// Stellt den Papierkorb dar: Der echte bleibt unberührt.
    private var trash: URL!
    private var library: MeetingLibrary!

    override func setUp() {
        base = files.temporaryDirectory.appendingPathComponent("steno-library-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Meetings", isDirectory: true)
        trash = base.appendingPathComponent("Papierkorb", isDirectory: true)
        MeetingStore.rootOverride = root
        library = MeetingLibrary()
    }

    override func tearDown() {
        MeetingStore.rootOverride = nil
        try? files.removeItem(at: base)
    }

    @discardableResult
    private func makeMeeting(_ title: String, at date: String = "2026-09-28T12:30:00Z", participants: String = "",
                             _ entries: MeetingEntry.Kind...) throws -> URL {
        let info = MeetingInfo(title: title, startedAt: ISO8601DateFormatter().date(from: date)!, duration: 600,
                               participants: participants, sources: [.microphone])
        let folder = try MeetingStore.makeFolder(for: info)
        let file = MeetingFile(info: info, entries: entries.enumerated().map { MeetingEntry(offset: Double($0.offset * 10), kind: $0.element) })
        try MeetingStore.write(file, to: folder)
        return folder
    }

    private func titles(_ items: [MeetingLibrary.Item]) -> [String] { items.map(\.info.title) }

    // MARK: Liste

    func testListsMeetingsNewestFirst() throws {
        let middle = try makeMeeting("Mitte", at: "2026-09-25T08:15:00Z")
        try makeMeeting("Neu", at: "2026-09-28T12:30:00Z")
        try makeMeeting("Alt", at: "2026-09-20T10:00:00Z")
        library.reload()
        XCTAssertEqual(titles(library.items), ["Neu", "Mitte", "Alt"])
        let item = try XCTUnwrap(library.items.first { $0.info.title == "Mitte" })
        XCTAssertEqual(item.folder, middle, "dieselbe Adresse, mit der der Ordner angelegt wurde")
        XCTAssertEqual(MeetingStore.read(item.folder)?.info, item.info)
    }

    func testReloadFollowsTheFolders() throws {
        try makeMeeting("Eins")
        library.reload()
        XCTAssertEqual(titles(library.items), ["Eins"])
        try makeMeeting("Zwei", at: "2026-09-29T09:00:00Z")
        library.reload()
        XCTAssertEqual(titles(library.items), ["Zwei", "Eins"])
        try files.removeItem(at: root)
        library.reload()
        XCTAssertEqual(library.items, [])
    }

    func testSkipsWhatIsNotAMeeting() throws {
        let real = try makeMeeting("Echt")
        let json = MeetingFile.fileName
        try files.createDirectory(at: root.appendingPathComponent("Ohne Datei"), withIntermediateDirectories: false)
        try files.createDirectory(at: root.appendingPathComponent("Kaputt"), withIntermediateDirectories: false)
        try Data("{".utf8).write(to: root.appendingPathComponent("Kaputt").appendingPathComponent(json))
        try files.createDirectory(at: root.appendingPathComponent("Sammlung/Innen"), withIntermediateDirectories: true)
        try files.copyItem(at: real.appendingPathComponent(json), to: root.appendingPathComponent("Sammlung/Innen").appendingPathComponent(json))
        try Data().write(to: root.appendingPathComponent("Lose Datei.txt"))
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        library.reload()
        XCTAssertEqual(titles(library.items), ["Echt"], "nur direkte Unterordner mit lesbarer meeting.json")
    }

    /// Die Liste liest nur die Angaben zum Meeting, nicht die ganze Mitschrift.
    func testListDoesNotNeedTheEntries() throws {
        let folder = try makeMeeting("Eins", .note("Rückruf"))
        let json = folder.appendingPathComponent(MeetingFile.fileName)
        let unknownKind = try String(contentsOf: json, encoding: .utf8).replacingOccurrences(of: "\"note\"", with: "\"neu\"")
        try Data(unknownKind.utf8).write(to: json)
        library.reload()
        XCTAssertEqual(titles(library.items), ["Eins"])
        XCTAssertNil(MeetingStore.read(folder), "zum Öffnen reicht es nicht – das sagt dann die Seite des Meetings")
    }

    // MARK: Suche

    func testEmptyQueryFindsEverything() throws {
        try makeMeeting("Eins")
        try makeMeeting("Zwei", at: "2026-09-29T09:00:00Z")
        library.reload()
        XCTAssertEqual(titles(library.items(matching: "")), ["Zwei", "Eins"])
        XCTAssertEqual(titles(library.items(matching: "  \n")), ["Zwei", "Eins"])
    }

    func testSearchIgnoresCaseAndAccents() throws {
        try makeMeeting("Müller Besprechung")
        try makeMeeting("Jour fixe", at: "2026-09-29T09:00:00Z")
        library.reload()
        XCTAssertEqual(titles(library.items(matching: "muller")), ["Müller Besprechung"])
        XCTAssertEqual(titles(library.items(matching: "MÜLLER")), ["Müller Besprechung"])
        XCTAssertEqual(titles(library.items(matching: "JOUR")), ["Jour fixe"])
        XCTAssertEqual(titles(library.items(matching: "  Besprechung ")), ["Müller Besprechung"])
        XCTAssertEqual(library.items(matching: "Sitzung"), [])
    }

    func testSearchLooksIntoParticipantsAndProtocolText() throws {
        try makeMeeting("Eins", participants: "Anna Meyer, Ben Weber")
        try makeMeeting("Zwei", at: "2026-09-29T09:00:00Z", .speech(.others, "Wir brauchen einen Kostenvoranschlag."), .note("Rückruf"))
        library.reload()
        XCTAssertEqual(titles(library.items(matching: "weber")), ["Eins"])
        XCTAssertEqual(titles(library.items(matching: "kostenvoranschlag")), ["Zwei"])
        XCTAssertEqual(titles(library.items(matching: "rueckruf")), [])
        XCTAssertEqual(titles(library.items(matching: "rückruf")), ["Zwei"])
    }

    func testSearchByTitleDoesNotNeedTheProtocolFile() throws {
        let folder = try makeMeeting("Eins")
        try files.removeItem(at: folder.appendingPathComponent(MeetingFile.markdownName))
        library.reload()
        XCTAssertEqual(titles(library.items(matching: "eins")), ["Eins"])
        XCTAssertEqual(library.items(matching: "verlauf"), [])
    }

    func testProtocolTextIsReadAgainOnlyWhenTheFileChanged() throws {
        let markdown = try makeMeeting("Eins", .note("alpha")).appendingPathComponent(MeetingFile.markdownName)
        // Ganze Sekunden, damit das Änderungsdatum beim Zurücksetzen genau dasselbe ist.
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try files.setAttributes([.modificationDate: stamp], ofItemAtPath: markdown.path)
        library.reload()
        XCTAssertEqual(library.items(matching: "alpha").count, 1)

        try Data("beta".utf8).write(to: markdown)
        try files.setAttributes([.modificationDate: stamp], ofItemAtPath: markdown.path)
        XCTAssertEqual(library.items(matching: "alpha").count, 1, "gleiches Änderungsdatum: der gemerkte Text gilt")
        XCTAssertEqual(library.items(matching: "beta").count, 0)

        try files.setAttributes([.modificationDate: stamp.addingTimeInterval(5)], ofItemAtPath: markdown.path)
        XCTAssertEqual(library.items(matching: "beta").count, 1, "neues Änderungsdatum: neu gelesen")
        XCTAssertEqual(library.items(matching: "alpha").count, 0)
    }

    // MARK: Papierkorb

    /// Tut, was der Papierkorb tut, nur in einem Ordner des Tests.
    private func fakeTrash(_ removed: @escaping (URL) -> Void) -> (URL) throws -> Void {
        let files = self.files, trash = self.trash!
        return { folder in
            removed(folder)
            try files.createDirectory(at: trash, withIntermediateDirectories: true)
            try files.moveItem(at: folder, to: trash.appendingPathComponent(folder.lastPathComponent))
        }
    }

    func testTrashMovesTheFolderAway() throws {
        let old = try makeMeeting("Alt", at: "2026-09-20T10:00:00Z")
        try makeMeeting("Neu")
        library.reload()
        var removed: [URL] = []
        library.trashFolder = fakeTrash { removed.append($0) }

        library.trash(try XCTUnwrap(library.items.last))
        XCTAssertEqual(removed, [old])
        XCTAssertEqual(titles(library.items), ["Neu"])
        XCTAssertFalse(files.fileExists(atPath: old.path))
        XCTAssertTrue(files.fileExists(atPath: trash.appendingPathComponent(old.lastPathComponent).path))
        library.reload()
        XCTAssertEqual(titles(library.items), ["Neu"])
    }

    func testFailedTrashKeepsTheMeeting() throws {
        let folder = try makeMeeting("Eins")
        library.reload()
        library.trashFolder = { _ in throw CocoaError(.fileWriteNoPermission) }
        library.trash(try XCTUnwrap(library.items.first))
        XCTAssertEqual(titles(library.items), ["Eins"])
        XCTAssertTrue(files.fileExists(atPath: folder.path))
    }
}
