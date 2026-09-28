import AppKit
import XCTest
@testable import Steno

final class MeetingStoreTests: XCTestCase {
    private let files = FileManager.default
    private var root: URL!

    private let sample = MeetingFile(
        info: MeetingInfo(title: "Übergabe Q3/Q4", startedAt: ISO8601DateFormatter().date(from: "2026-09-28T12:30:00Z")!,
                          duration: 3930.5, participants: "Anna Meyer, Ben Weber", othersName: "Herr Meier",
                          sources: [.microphone, .systemAudio]),
        entries: [
            MeetingEntry(offset: 12.25, kind: .speech(.you, "Guten Morgen, und/oder guten Abend.")),
            MeetingEntry(offset: 20, kind: .speech(.others, "Können wir anfangen?")),
            MeetingEntry(offset: 760, kind: .task("Angebot schicken")),
            MeetingEntry(offset: 775, kind: .note("Preis prüfen")),
            MeetingEntry(offset: 782, kind: .mark),
            MeetingEntry(offset: 790, kind: .image("13-10.png")),
        ])

    override func setUp() {
        root = files.temporaryDirectory.appendingPathComponent("steno-meetings-\(UUID().uuidString)", isDirectory: true)
        MeetingStore.rootOverride = root
    }

    override func tearDown() {
        MeetingStore.rootOverride = nil
        try? files.removeItem(at: root)
    }

    /// Ortszeit, damit der Ordnername nicht von der Zeitzone des Rechners abhängt.
    private func info(_ title: String, hour: Int = 14, minute: Int = 30) -> MeetingInfo {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: hour, minute: minute))!
        return MeetingInfo(title: title, startedAt: start, sources: [.microphone])
    }

    private func folderName(_ title: String, minute: Int = 30) throws -> String {
        try MeetingStore.makeFolder(for: info(title, minute: minute)).lastPathComponent
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return files.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Ordner

    func testFolderHasLocalTimeAndTitleAndRootIsCreated() throws {
        XCTAssertFalse(files.fileExists(atPath: root.path))
        let folder = try MeetingStore.makeFolder(for: info("Wochenplanung"))
        XCTAssertEqual(folder.lastPathComponent, "2026-09-28 14-30 Wochenplanung")
        XCTAssertEqual(folder.deletingLastPathComponent().path, root.path)
        XCTAssertTrue(isFolder(folder))
        XCTAssertEqual(try MeetingStore.makeFolder(for: info("Später", hour: 9, minute: 5)).lastPathComponent, "2026-09-28 09-05 Später")
    }

    func testTitleIsCleaned() throws {
        XCTAssertEqual(try folderName("Q3/Q4: Planung\\Ziele"), "2026-09-28 14-30 Q3 Q4 Planung Ziele")
        XCTAssertEqual(try folderName("  Zeile eins\nZeile zwei\r\n  "), "2026-09-28 14-30 Zeile eins Zeile zwei")
        XCTAssertEqual(try folderName("Größe ändern – 会議"), "2026-09-28 14-30 Größe ändern – 会議")
        XCTAssertEqual(try folderName("100% Fokus #1"), "2026-09-28 14-30 100% Fokus #1")
    }

    func testEmptyTitleBecomesMeeting() throws {
        XCTAssertEqual(try folderName("", minute: 1), "2026-09-28 14-01 Meeting")
        XCTAssertEqual(try folderName(" \n ", minute: 2), "2026-09-28 14-02 Meeting")
        XCTAssertEqual(try folderName("/:\\", minute: 3), "2026-09-28 14-03 Meeting")
    }

    func testLongTitleIsCutAtAboutSixtyCharacters() throws {
        let name = try folderName(String(repeating: "abcdefghi ", count: 10))
        XCTAssertEqual(name, "2026-09-28 14-30 " + String(repeating: "abcdefghi ", count: 6).trimmingCharacters(in: .whitespaces))
    }

    func testSameNameGetsANumber() throws {
        XCTAssertEqual(try folderName("Daily"), "2026-09-28 14-30 Daily")
        XCTAssertEqual(try folderName("Daily"), "2026-09-28 14-30 Daily 2")
        XCTAssertEqual(try folderName("Daily"), "2026-09-28 14-30 Daily 3")
        XCTAssertEqual(try folderName("Daily 2"), "2026-09-28 14-30 Daily 2 2")
    }

    func testUnusableRootIsReported() throws {
        files.createFile(atPath: root.path, contents: Data())
        XCTAssertThrowsError(try MeetingStore.makeFolder(for: info("Titel"))) { error in
            guard case MeetingError.folderUnavailable(let name) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, root.lastPathComponent)
        }
    }

    // MARK: Schreiben und Lesen

    func testWriteAndReadRoundTrip() throws {
        let folder = try MeetingStore.makeFolder(for: sample.info)
        try MeetingStore.write(sample, to: folder)
        XCTAssertEqual(MeetingStore.read(folder), sample)
    }

    func testWritesJsonAndMarkdownAndNothingElse() throws {
        let folder = try MeetingStore.makeFolder(for: sample.info)
        try MeetingStore.write(sample, to: folder)
        try MeetingStore.write(sample, to: folder)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.path).sorted(), ["Protokoll.md", "meeting.json"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Protokoll.md"), encoding: .utf8),
                       MeetingStore.markdown(for: sample))

        let json = try String(contentsOf: folder.appendingPathComponent("meeting.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"startedAt\" : \"2026-09-28T12:30:00Z\""), "ISO 8601, gut lesbar eingerückt")
        XCTAssertTrue(json.contains("und/oder"), "Schrägstriche bleiben lesbar")
        XCTAssertLessThan(try XCTUnwrap(json.range(of: "\"entries\"")).lowerBound, try XCTUnwrap(json.range(of: "\"info\"")).lowerBound)
        XCTAssertLessThan(try XCTUnwrap(json.range(of: "\"duration\"")).lowerBound, try XCTUnwrap(json.range(of: "\"title\"")).lowerBound)
    }

    func testWriteReplacesEarlierVersion() throws {
        let folder = try MeetingStore.makeFolder(for: sample.info)
        try MeetingStore.write(sample, to: folder)
        var changed = sample
        changed.info.title = "Neuer Titel"
        changed.entries.removeLast()
        try MeetingStore.write(changed, to: folder)
        XCTAssertEqual(MeetingStore.read(folder), changed)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("Protokoll.md"), encoding: .utf8).hasPrefix("# Neuer Titel\n"))
    }

    func testWriteToMissingFolderThrows() {
        let missing = root.appendingPathComponent("gibt es nicht", isDirectory: true)
        XCTAssertThrowsError(try MeetingStore.write(sample, to: missing)) { error in
            guard case MeetingError.folderUnavailable(let name) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "gibt es nicht")
        }
    }

    func testDamagedFilesReadAsNil() throws {
        let folder = try MeetingStore.makeFolder(for: sample.info)
        let file = folder.appendingPathComponent(MeetingFile.fileName)
        XCTAssertNil(MeetingStore.read(folder), "keine Datei")

        try MeetingStore.write(sample, to: folder)
        let valid = try Data(contentsOf: file)
        let damaged = [Data(), Data("kein json".utf8), Data("{\"info\": 5}".utf8), Data("[]".utf8), valid.prefix(valid.count / 2)]
        for data in damaged {
            try data.write(to: file)
            XCTAssertNil(MeetingStore.read(folder), String(decoding: data.prefix(20), as: UTF8.self))
        }

        try files.removeItem(at: file)
        try files.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertNil(MeetingStore.read(folder), "ein Ordner statt der Datei")
    }

    // MARK: Bilder

    /// Ein Retina-Screenshot: doppelt so viele Bildpunkte wie Punkte.
    private func retinaImage() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 20, height: 10)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    func testImageIsSavedAsFullResolutionPNG() throws {
        let folder = try MeetingStore.makeFolder(for: sample.info)
        let name = try MeetingStore.saveImage(retinaImage(), at: 760, in: folder)
        XCTAssertEqual(name, "12-40.png")
        let data = try Data(contentsOf: folder.appendingPathComponent("bilder").appendingPathComponent(name))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG-Kennung")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 40)
        XCTAssertEqual(rep.pixelsHigh, 20)
    }

    func testImageNamesFollowTheOffset() throws {
        let folder = try MeetingStore.makeFolder(for: sample.info)
        let image = retinaImage()
        XCTAssertEqual(try MeetingStore.saveImage(image, at: 5, in: folder), "0-05.png")
        XCTAssertEqual(try MeetingStore.saveImage(image, at: 3599, in: folder), "59-59.png")
        XCTAssertEqual(try MeetingStore.saveImage(image, at: 3930, in: folder), "1-05-30.png")
        XCTAssertEqual(try MeetingStore.saveImage(image, at: -1, in: folder), "0-00.png")
    }

    func testImageWithTheSameNameGetsANumber() throws {
        let folder = try MeetingStore.makeFolder(for: sample.info)
        let image = retinaImage()
        XCTAssertEqual(try MeetingStore.saveImage(image, at: 760, in: folder), "12-40.png")
        XCTAssertEqual(try MeetingStore.saveImage(image, at: 760.9, in: folder), "12-40-2.png")
        XCTAssertEqual(try MeetingStore.saveImage(image, at: 760, in: folder), "12-40-3.png")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.appendingPathComponent("bilder").path).count, 3)
    }

    func testImageFolderExistsOnlyWithTheFirstImage() throws {
        let folder = try MeetingStore.makeFolder(for: sample.info)
        let images = folder.appendingPathComponent("bilder")
        try MeetingStore.write(sample, to: folder)
        XCTAssertFalse(files.fileExists(atPath: images.path))
        XCTAssertThrowsError(try MeetingStore.saveImage(NSImage(), at: 1, in: folder), "ein Bild ohne Bildpunkte")
        XCTAssertFalse(files.fileExists(atPath: images.path))
        _ = try MeetingStore.saveImage(retinaImage(), at: 1, in: folder)
        XCTAssertTrue(isFolder(images))
    }
}
