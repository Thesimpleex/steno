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

    private func press(_ code: Int64, _ raw: UInt64) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.flags = CGEventFlags(rawValue: raw)
        _ = monitor.feed(.keyDown, event)
    }

    /// Der Monitor meldet über den Hauptthread – kurz laufen lassen, dann einsammeln.
    private func drain() -> [String] {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        defer { events = [] }
        return events
    }
}
