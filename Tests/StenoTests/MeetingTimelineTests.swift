import SwiftUI
import XCTest
@testable import Steno

final class MeetingTimelineTests: XCTestCase {
    /// Eine von Hand bearbeitete meeting.json kann unsinnige Zeiten enthalten; die Zeitleiste zeigt sie trotzdem an.
    func testDamagedOffsetsDoNotCrash() {
        let entries = [MeetingEntry(offset: -3, kind: .note("Davor")), MeetingEntry(offset: 1e300, kind: .mark)]
        let timeline = NSHostingView(rootView: MeetingTimeline(entries: entries, othersLabel: "Andere", folder: nil))
        XCTAssertGreaterThan(timeline.fittingSize.height, 0)
    }

    func testFollowsNewContentWhileAtTheEnd() {
        var tail = TailFollow()
        XCTAssertTrue(tail.update(offset: 0, content: 300, viewport: 400), "beim Erscheinen ans Ende")
        XCTAssertFalse(tail.update(offset: 0, content: 300, viewport: 400), "nichts Neues, nichts zu tun")
        XCTAssertTrue(tail.update(offset: 0, content: 360, viewport: 400), "kurze Liste: unten ist oben")
        XCTAssertTrue(tail.update(offset: 0, content: 480, viewport: 400), "jetzt läuft der neue Eintrag unten aus dem Bild")
        XCTAssertFalse(tail.update(offset: 80, content: 480, viewport: 400), "angekommen")
        XCTAssertTrue(tail.update(offset: 80, content: 540, viewport: 400))
    }

    func testStopsFollowingWhenScrolledUpAndResumesAtTheEnd() {
        var tail = TailFollow()
        _ = tail.update(offset: 0, content: 800, viewport: 400)
        _ = tail.update(offset: 400, content: 800, viewport: 400)
        XCTAssertFalse(tail.update(offset: 150, content: 800, viewport: 400), "nach oben gescrollt")
        XCTAssertFalse(tail.following)
        XCTAssertFalse(tail.update(offset: 150, content: 860, viewport: 400), "wer oben liest, wird nicht nach unten gerissen")
        XCTAssertFalse(tail.update(offset: 300, content: 860, viewport: 400), "weiter nach unten, aber noch nicht am Ende")
        XCTAssertFalse(tail.following)
        XCTAssertFalse(tail.update(offset: 460, content: 860, viewport: 400), "am Ende angekommen")
        XCTAssertTrue(tail.following)
        XCTAssertTrue(tail.update(offset: 460, content: 920, viewport: 400), "ab jetzt wieder mit")
    }

    func testKeepsTheEndInViewWhenTheViewShrinks() {
        var tail = TailFollow()
        _ = tail.update(offset: 400, content: 800, viewport: 400)
        XCTAssertTrue(tail.resize(to: 340), "eine Meldung nimmt oben Platz weg: das Ende soll im Bild bleiben")
        XCTAssertFalse(tail.resize(to: 340), "gleiche Größe: nichts zu tun")
        _ = tail.update(offset: 100, content: 800, viewport: 340)  // jetzt weiter oben lesen
        XCTAssertFalse(tail.resize(to: 300), "wer oben liest, bleibt dort")
    }

    func testAnimatedScrollAndBouncingDoNotCountAsScrollingUp() {
        var tail = TailFollow()
        _ = tail.update(offset: 0, content: 800, viewport: 400)
        for offset in stride(from: 40.0, through: 400.0, by: 60.0) {  // die Animation zum Ende
            _ = tail.update(offset: CGFloat(offset), content: 800, viewport: 400)
            XCTAssertTrue(tail.following, "Offset \(offset)")
        }
        _ = tail.update(offset: 430, content: 800, viewport: 400)  // Gummiband unter dem Ende …
        _ = tail.update(offset: 410, content: 800, viewport: 400)  // … und zurück
        XCTAssertTrue(tail.following)
    }
}
