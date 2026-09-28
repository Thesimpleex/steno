import AppKit
import XCTest
@testable import Steno

/// Ob in der Zwischenablage ein neues Bild von außen liegt – mit einer eigenen Ablage, nie mit der echten.
final class ClipboardImagesTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var seen = 0
    /// Der Zählerstand, den Steno selbst erzeugt hat, wie `TextInsertion.ownChangeCount`.
    private var own = 0

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("steno.tests.\(UUID().uuidString)"))
        seen = pasteboard.changeCount
        own = 0
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testDeliversAnImageFromOutsideOnce() {
        copyImage()
        XCTAssertEqual(next()?.size, NSSize(width: 4, height: 3))
        XCTAssertNil(next(), "dasselbe Bild kein zweites Mal")
    }

    func testReadsPngAndTiff() {
        copyImage(.png)
        XCTAssertNotNil(next())
        copyImage(.tiff)
        XCTAssertNotNil(next())
    }

    func testIgnoresWhatWasThereBeforeTheMeeting() {
        copyImage()
        seen = pasteboard.changeCount
        XCTAssertNil(next())
    }

    func testIgnoresText() {
        pasteboard.clearContents()
        pasteboard.setString("Hallo", forType: .string)
        XCTAssertNil(next())
        copyImage()
        XCTAssertNotNil(next(), "ein Bild danach wird trotzdem erkannt")
    }

    func testIgnoresImagesThatComeWithMore() {
        let url = NSURL(fileURLWithPath: "/tmp/Bericht.pdf").absoluteString!
        let extras: [(NSPasteboard.PasteboardType, String)] = [
            (.fileURL, url),  // ⌘C auf eine Datei im Finder legt ihr Symbol als TIFF dazu
            (.string, "Tabelle"), (.rtf, "{\\rtf1 Folie}"), (.html, "<b>Seite</b>"),
            (.init("org.nspasteboard.TransientType"), ""), (.init("org.nspasteboard.ConcealedType"), ""),
        ]
        for (type, value) in extras {
            pasteboard.clearContents()
            pasteboard.setData(imageData(.tiff), forType: .tiff)
            pasteboard.setString(value, forType: type)
            XCTAssertNil(next(), "\(type.rawValue)")
        }
    }

    func testIgnoresTheImageStenoPutBack() {
        copyImage()
        XCTAssertNotNil(next())
        pasteDictation()
        XCTAssertNil(next())
        restoreImage()
        XCTAssertNil(next(), "das zurückgelegte Bild ist kein neues")
    }

    func testIgnoresARestoredImageThatWasNeverSeen() {
        copyImage()  // liegt schon da, wenn Steno einfügt – die nächste Abfrage kommt erst danach
        pasteDictation()
        restoreImage()
        XCTAssertNil(next())
    }

    func testDeliversAnImageThatArrivesAfterStenoPasted() {
        pasteDictation()
        XCTAssertNil(next())
        copyImage()
        XCTAssertNotNil(next())
    }

    // MARK: Hilfen

    private func next() -> NSImage? {
        ClipboardImages.newImage(in: pasteboard, seen: &seen, ownChangeCount: own)
    }

    private func imageData(_ type: NSBitmapImageRep.FileType) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: type, properties: [:])!
    }

    /// Ein Bildschirmausschnitt von außen, wie ihn ⌘⌃⇧4 in die Ablage legt.
    private func copyImage(_ type: NSPasteboard.PasteboardType = .png) {
        pasteboard.clearContents()
        pasteboard.setData(imageData(type == .png ? .png : .tiff), forType: type)
    }

    /// Steno legt das Diktat in die Ablage und vermerkt den Zählerstand, so wie `TextInsertion.paste`.
    private func pasteDictation() {
        pasteboard.clearContents()
        pasteboard.setString("Diktat", forType: .string)
        own = pasteboard.changeCount
    }

    /// Danach legt Steno den alten Inhalt zurück – hier das Bild.
    private func restoreImage() {
        pasteboard.clearContents()
        pasteboard.setData(imageData(.png), forType: .png)
        own = pasteboard.changeCount
    }
}
