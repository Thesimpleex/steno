import XCTest
@testable import Steno

final class SpacingTests: XCTestCase {
    func testSpaceOnlyAfterText() {
        let spacing = Dictation.Spacing()
        XCTAssertTrue(spacing.needed(before: "a", in: "app"))
        XCTAssertFalse(spacing.needed(before: " ", in: "app"))
        XCTAssertFalse(spacing.needed(before: "(", in: "app"))
        XCTAssertFalse(spacing.needed(before: "", in: "app"), "am Feldanfang")
    }

    /// Im Terminal lässt sich das Zeichen vor dem Cursor nicht lesen – dann zählt, ob gerade eben dorthin diktiert wurde.
    func testUnreadableCursorFollowsTheLastDictation() {
        var spacing = Dictation.Spacing()
        let now = Date.now
        XCTAssertFalse(spacing.needed(before: nil, in: "terminal", now: now))
        spacing.inserted(in: "terminal", sent: false, now: now)
        XCTAssertTrue(spacing.needed(before: nil, in: "terminal", now: now + 5))
        XCTAssertFalse(spacing.needed(before: nil, in: "editor", now: now + 5))
        XCTAssertFalse(spacing.needed(before: nil, in: "terminal", now: now + 121))
    }

    /// Nach Return beginnt eine neue Zeile: Das nächste Diktat dort bekommt kein Leerzeichen davor.
    func testNoSpaceAfterSending() {
        var spacing = Dictation.Spacing()
        let now = Date.now
        spacing.inserted(in: "terminal", sent: false, now: now)
        spacing.inserted(in: "terminal", sent: true, now: now + 1)
        XCTAssertFalse(spacing.needed(before: nil, in: "terminal", now: now + 2))
    }
}
