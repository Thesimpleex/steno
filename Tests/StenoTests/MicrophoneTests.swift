import XCTest
@testable import Steno

/// Welche Puffer zur Aufnahme zählen – ohne Mikrofon, nur die Buchführung zwischen den Threads.
final class MicrophoneTests: XCTestCase {
    func testOnlyTheRunningDeviceCounts() {
        var capture = Microphone.Capture()
        let id = capture.request()
        XCTAssertNil(capture.receive([1], from: 1, keeping: true), "vor dem Start zählt nichts")
        XCTAssertTrue(capture.begin(id, engine: 1))
        XCTAssertEqual(capture.receive([1, 2], from: 1, keeping: true), true, "der erste Puffer wird gemeldet")
        XCTAssertEqual(capture.receive([3], from: 1, keeping: true), false)
        XCTAssertNil(capture.receive([9], from: 2, keeping: true), "ein anderes Gerät zählt nicht")
        XCTAssertEqual(capture.samples, [1, 2, 3])
        XCTAssertTrue(capture.isLive(1))
        XCTAssertEqual(capture.end(), [1, 2, 3])
        XCTAssertFalse(capture.isLive(1))
        XCTAssertFalse(capture.isWanted(id))
    }

    func testLateBuffersAfterTheEndAreDropped() {
        var capture = Microphone.Capture()
        XCTAssertTrue(capture.begin(capture.request(), engine: 1))
        _ = capture.receive([1], from: 1, keeping: true)
        _ = capture.end()
        XCTAssertNil(capture.receive([2], from: 1, keeping: true), "Puffer eines Geräts, das gerade anhält")
        XCTAssertTrue(capture.begin(capture.request(), engine: 2))
        XCTAssertEqual(capture.receive([3], from: 2, keeping: true), true, "jede Aufnahme meldet ihren ersten Puffer")
        XCTAssertEqual(capture.end(), [3])
    }

    /// Kürzel wie ⌥L beenden die Aufnahme, bevor das Mikrofon läuft – dann darf es gar nicht erst angehen.
    func testRecordingEndedBeforeItsDeviceStarts() {
        var capture = Microphone.Capture()
        let first = capture.request()
        _ = capture.end()
        XCTAssertFalse(capture.begin(first, engine: 1))
        let second = capture.request()
        XCTAssertFalse(capture.begin(first, engine: 1), "eine ältere Aufnahme startet nicht mehr")
        XCTAssertTrue(capture.isWanted(second))
        XCTAssertTrue(capture.begin(second, engine: 1))
    }

    /// Meetings starten ohne Nummer und sammeln nicht, sie bekommen die Abschnitte einzeln.
    func testMeetingsStartDirectlyAndDoNotCollect() {
        var capture = Microphone.Capture()
        XCTAssertTrue(capture.begin(nil, engine: 1))
        XCTAssertEqual(capture.receive([1, 2], from: 1, keeping: false), true)
        XCTAssertEqual(capture.samples, [])
    }
}

/// Welches Mikrofon geöffnet wird – ein Bluetooth-Headset nur, wenn es nicht anders geht.
final class MicrophoneChoiceTests: XCTestCase {
    func testBluetoothDefaultFallsBackToTheBuiltInMicrophone() {
        XCTAssertEqual(Microphone.choose(defaultIsBluetooth: true, lidClosed: false, builtInAvailable: true), .builtIn)
    }

    func testBluetoothStaysWhenTheBuiltInMicrophoneCannotHear() {
        XCTAssertEqual(Microphone.choose(defaultIsBluetooth: true, lidClosed: true, builtInAvailable: true), .systemDefault,
                       "zugeklappt ist das eingebaute stumm")
        XCTAssertEqual(Microphone.choose(defaultIsBluetooth: true, lidClosed: false, builtInAvailable: false), .systemDefault,
                       "etwa ein Mac mini ohne Mikrofon")
    }

    func testOtherMicrophonesFollowTheSystemSetting() {
        XCTAssertEqual(Microphone.choose(defaultIsBluetooth: false, lidClosed: false, builtInAvailable: true), .systemDefault)
        XCTAssertEqual(Microphone.choose(defaultIsBluetooth: false, lidClosed: true, builtInAvailable: true), .systemDefault)
    }
}
