import AppKit
import XCTest
@testable import Steno

/// Return und Esc im Notizfeld, ohne ein Fenster zu zeigen.
final class QuickNoteTests: XCTestCase {
    private var meeting: MeetingSession!
    private var overlay: NotchOverlay!
    private var note: QuickNote!

    override func setUp() {
        meeting = MeetingSession(state: .running, info: MeetingInfo(title: "Test", startedAt: .now, sources: [.microphone]))
        overlay = NotchOverlay()
        overlay.model.state = .working  // eine laufende Anzeige bleibt stehen, es erscheint also nichts auf dem Bildschirm
        note = QuickNote(meeting: meeting, overlay: overlay)
    }

    func testReturnSavesNoteTaskAndMark() {
        XCTAssertEqual(command(#selector(NSResponder.insertNewline(_:)), typing: "Budget klären"), .note("Budget klären"))
        XCTAssertEqual(command(#selector(NSResponder.insertNewline(_:)), typing: "!Angebot schicken"), .task("Angebot schicken"))
        XCTAssertEqual(command(#selector(NSResponder.insertNewline(_:)), typing: ""), .mark)
        XCTAssertEqual(command(#selector(NSResponder.insertNewline(_:)), typing: " ! "), .mark, "keine leere Aufgabe")
        XCTAssertEqual(meeting.entries.count, 4)
    }

    func testPastedLineBreaksBecomeOneLine() {
        XCTAssertEqual(command(#selector(NSResponder.insertNewline(_:)), typing: "erste\nzweite"), .note("erste zweite"))
    }

    func testEscapeSavesNothing() {
        XCTAssertNil(command(#selector(NSResponder.cancelOperation(_:)), typing: "Budget klären"))
        XCTAssertTrue(meeting.entries.isEmpty)
    }

    func testOtherCommandsAreLeftToTheField() {
        XCTAssertNil(command(#selector(NSResponder.moveLeft(_:)), typing: "Budget klären", handled: false))
        XCTAssertTrue(meeting.entries.isEmpty)
    }

    func testConfirmationDoesNotDisplaceADictation() {
        _ = command(#selector(NSResponder.insertNewline(_:)), typing: "Budget klären")
        XCTAssertEqual(overlay.model.state, .working)
    }

    func testPanelSitsBelowTheNotchOrAboveTheBubble() {
        let area = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let size = NSSize(width: 480, height: 74)
        let notch = NSRect(x: 600, y: 944, width: 312, height: 38)
        XCTAssertEqual(QuickNote.origin(for: size, in: area, anchor: notch), NSPoint(x: 516, y: 944 - 74 - 8))
        let bubble = NSRect(x: 690, y: 20, width: 132, height: 32)
        XCTAssertEqual(QuickNote.origin(for: size, in: area, anchor: bubble), NSPoint(x: 516, y: 60), "unten kein Platz: darüber")
        let edge = NSRect(x: 0, y: 944, width: 100, height: 38)
        XCTAssertEqual(QuickNote.origin(for: size, in: area, anchor: edge).x, 8, "bleibt auf dem Bildschirm")
        XCTAssertEqual(QuickNote.origin(for: size, in: area, anchor: nil), NSPoint(x: 516, y: 944 - 74 - 64))
    }

    /// Nur Ergebnis und Meeting-Anzeige nehmen die Maus an – ein Diktat blockiert nie die Menüleiste.
    func testOnlyResultAndMeetingAcceptClicks() {
        XCTAssertTrue(OverlayModel.State.meeting.acceptsMouse)
        XCTAssertTrue(OverlayModel.State.result("x").acceptsMouse)
        for state: OverlayModel.State in [.hidden, .recording(handsFree: false), .recording(handsFree: true), .working, .message("x")] {
            XCTAssertFalse(state.acceptsMouse, "\(state)")
        }
    }

    // MARK: Hilfen

    /// Schickt den Befehl an das Feld und liefert den Eintrag, der dadurch neu in der Zeitleiste steht.
    private func command(_ selector: Selector, typing text: String, handled: Bool = true) -> MeetingEntry.Kind? {
        let editor = NSTextView()
        editor.string = text
        let before = meeting.entries.count
        XCTAssertEqual(note.control(NSTextField(), textView: editor, doCommandBy: selector), handled)
        return meeting.entries.count > before ? meeting.entries.last?.kind : nil
    }
}
