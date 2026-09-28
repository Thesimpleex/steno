import CoreGraphics
import XCTest
@testable import Steno

/// Spielt für jede wählbare Taste Drücken, Loslassen und Tastenkürzel mit simulierten Ereignissen durch.
final class HotKeyMonitorTests: XCTestCase {
    private var monitor: HotKeyMonitor!
    private var events: [String] = []

    override func setUp() {
        monitor = HotKeyMonitor()
        events = []
        monitor.handler = { [unowned self] event in
            switch event {
            case .down: events.append("down")
            case .up: events.append("up")
            case .chord: events.append("chord")
            case .escape: events.append("esc")
            case .pasteLast: events.append("paste")
            case .note: events.append("note")
            case .send: events.append("send")
            }
        }
    }

    func testEveryKeyHoldsAndReleases() {
        for key in HotKey.allCases {
            monitor.hotKey = key
            flags(key.keyCode, down(key))
            flags(key.keyCode, 0)
            XCTAssertEqual(drain(), ["down", "up"], "\(key)")
        }
    }

    func testTypingWhileHoldingIsAChord() {
        for key in HotKey.allCases {
            monitor.hotKey = key
            flags(key.keyCode, down(key))
            press(0, down(key))
            flags(key.keyCode, 0)
            XCTAssertEqual(drain(), ["down", "chord", "up"], "\(key)")
        }
    }

    func testClickWhileHoldingIsAChord() {
        for key in HotKey.allCases {
            monitor.hotKey = key
            flags(key.keyCode, down(key))
            let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            XCTAssertFalse(monitor.feed(.leftMouseDown, click), "Klicks werden nie verschluckt")
            flags(key.keyCode, 0)
            XCTAssertEqual(drain(), ["down", "chord", "up"], "\(key)")
        }
    }

    func testIgnoresKeyAddedToAnotherModifier() {
        for key in HotKey.allCases where key != .rightCommand {
            monitor.hotKey = key
            let leftCommand: UInt64 = 0x08 | CGEventFlags.maskCommand.rawValue
            flags(key.keyCode, down(key) | leftCommand)
            flags(key.keyCode, leftCommand)
            XCTAssertEqual(drain(), [], "\(key)")
        }
    }

    func testOtherKeysDoNothing() {
        for key in HotKey.allCases {
            monitor.hotKey = key
            for other in HotKey.allCases where other != key {
                flags(other.keyCode, down(other))
                flags(other.keyCode, 0)
            }
            XCTAssertEqual(drain(), [], "\(key)")
        }
    }

    func testReleaseCountsForTheKeyThatWasHeld() {
        monitor.hotKey = .leftOption
        flags(HotKey.leftOption.keyCode, down(.leftOption))
        monitor.hotKey = .rightCommand
        flags(HotKey.leftOption.keyCode, 0)
        XCTAssertEqual(drain(), ["down", "up"])
    }

    func testEscapeIsReported() {
        press(53, 0)
        XCTAssertEqual(drain(), ["esc"])
    }

    func testReturnBelongsToTheRecording() {
        XCTAssertFalse(press(36, 0), "ohne Aufnahme geht Return an die App")
        XCTAssertEqual(drain(), [])
        monitor.isRecording = true
        XCTAssertTrue(press(36, 0))
        XCTAssertTrue(press(76, 0), "auch Enter auf dem Ziffernblock")
        XCTAssertEqual(drain(), ["send", "send"])
    }

    func testReturnIsNotAChord() {
        monitor.hotKey = .leftOption
        flags(HotKey.leftOption.keyCode, down(.leftOption))
        monitor.isRecording = true
        press(36, down(.leftOption))
        flags(HotKey.leftOption.keyCode, 0)
        XCTAssertEqual(drain(), ["down", "send", "up"])
    }

    func testNoteShortcutOnlyDuringMeeting() {
        let chord = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        let n = Int64(KeyLayout.n)
        XCTAssertFalse(press(n, chord), "ohne Meeting bleibt das Kürzel frei")
        XCTAssertEqual(drain(), [])
        monitor.isMeeting = true
        XCTAssertTrue(press(n, chord))
        XCTAssertFalse(press(n, CGEventFlags.maskControl.rawValue), "nur mit ⌃⌥")
        XCTAssertEqual(drain(), ["note"])
    }

    // MARK: Hilfen

    /// Flags, die macOS beim Drücken der Taste mitschickt: das Bit der Taste selbst und das Sammel-Bit.
    private func down(_ key: HotKey) -> UInt64 {
        switch key {
        case .leftOption, .rightOption: return key.flag | CGEventFlags.maskAlternate.rawValue
        case .rightCommand: return key.flag | CGEventFlags.maskCommand.rawValue
        case .leftControl, .rightControl: return key.flag | CGEventFlags.maskControl.rawValue
        case .rightShift: return key.flag | CGEventFlags.maskShift.rawValue
        case .function: return key.flag
        }
    }

    private func flags(_ code: Int64, _ raw: UInt64) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: raw)
        _ = monitor.feed(.flagsChanged, event)
    }

    /// Liefert, ob der Monitor die Taste verschluckt hat.
    @discardableResult
    private func press(_ code: Int64, _ raw: UInt64) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.flags = CGEventFlags(rawValue: raw)
        return monitor.feed(.keyDown, event)
    }

    /// Der Monitor meldet über den Hauptthread, und was er bis hierher gemeldet hat, steht dort schon an: Ist eine
    /// Markierung dahinter an der Reihe, ist alles angekommen – anders als nach einer festen Wartezeit auch unter Last.
    private func drain() -> [String] {
        let delivered = expectation(description: "alle Meldungen zugestellt")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 5)
        defer { events = [] }
        return events
    }
}
