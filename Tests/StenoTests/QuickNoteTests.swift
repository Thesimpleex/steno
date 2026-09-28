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
        XCTAssertEqual(meeting.entries.count, 3)
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
