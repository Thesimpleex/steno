import AppKit
import XCTest
@testable import Steno

/// Die Sitzung mit Attrappen: Tonquellen, die der Test füttert, eine Umwandlung ohne Whisper und eine Ablage im
/// Speicher – kein Mikrofon, keine Freigabe, keine Datei.
final class MeetingSessionTests: XCTestCase {
    private var you: FakeSource!
    private var others: FakeSource!
    private var files: FakeFiling!
    private var session: MeetingSession!

    override func setUp() {
        you = FakeSource()
        others = FakeSource()
        files = FakeFiling()
        session = MeetingSession(microphone: you, systemAudio: others, filing: files.filing)
        var count = 0
        session.transcription = { _, done in
            count += 1
            done("Beitrag \(count)")
        }
    }

    override func tearDown() {
        session.stop()
    }

    // MARK: Zeitleiste

    func testTimelineStaysSortedByTime() {
        var entries: [MeetingEntry] = []
        entries.addSpeech("Drittens", by: .you, at: 30)
        entries.addSpeech("Erstens", by: .others, at: 10)
        entries.insertSorted(MeetingEntry(offset: 20, kind: .mark))
        entries.addSpeech("Zweitens", by: .you, at: 20)
        XCTAssertEqual(entries.map(\.offset), [10, 20, 20, 30])
        XCTAssertEqual(entries[1].kind, .mark, "bei gleicher Zeit kommt das Neue dahinter")
    }

    func testEchoFromTheSpeakersIsDropped() {
        let theirs = "Wir treffen uns am Montag um zehn Uhr im Büro."
        let echo = "Wir treffen uns am Montag um 10 Uhr im Büro."
        var entries: [MeetingEntry] = []
        entries.addSpeech(theirs, by: .others, at: 60)
        entries.addSpeech(echo, by: .you, at: 62)
        XCTAssertEqual(entries.map(\.kind), [.speech(.others, theirs)], "Echo nach dem Original fertig")

        entries = []
        entries.addSpeech(echo, by: .you, at: 62)
        entries.addSpeech(theirs, by: .others, at: 60)
        XCTAssertEqual(entries.map(\.kind), [.speech(.others, theirs)], "Echo vor dem Original fertig")

        entries = []
        entries.addSpeech(theirs, by: .others, at: 60)
        entries.addSpeech(echo, by: .you, at: 80)
        entries.addSpeech("Ja, genau.", by: .others, at: 90)
        entries.addSpeech("Ja, genau.", by: .you, at: 91)
        entries.addSpeech("Und am Dienstag treffen wir den Kunden.", by: .you, at: 95)
        XCTAssertEqual(entries.count, 5, "später, kurz oder etwas anderes gesagt: kein Echo")
    }

    // MARK: Ablauf

    func testRefusesToStartWithoutModelOrSourceOrTwice() throws {
        let whisper = session.transcription
        session.transcription = nil
        assertThrows(.noModel) { try start(.microphone) }
        session.transcription = whisper
        assertThrows(.noSource) { try start([]) }
        try start(.microphone)
        assertThrows(.alreadyRunning) { try start(.microphone) }
        XCTAssertEqual([you.starts, others.starts], [1, 0])
    }

    /// Wartet der Ton des Macs auf die Freigabe, bleibt der Hauptthread frei. Das Meeting beginnt erst mit der Antwort;
    /// was das Mikrofon bis dahin hört, gehört nicht dazu, und ein zweiter Klick startet nichts noch einmal.
    func testWaitingForPermissionKeepsTheMainThreadFree() {
        let permission = DispatchSemaphore(value: 0)
        others.waitsFor = permission
        var answers = 0
        session.start(title: "", sources: [.microphone, .systemAudio]) { _ in answers += 1 }
        XCTAssertTrue(session.isStarting, "die Seite zeigt, dass gestartet wird")
        session.start(title: "", sources: [.microphone, .systemAudio]) { _ in answers += 1 }
        you.play(TestAudio.speech(6) + TestAudio.silence(1))
        RunLoop.main.run(until: .now + 0.1)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(answers, 0)
        XCTAssertTrue(session.isStarting)

        permission.signal()
        wait { answers == 1 }
        XCTAssertEqual(session.state, .running)
        XCTAssertFalse(session.isStarting)
        RunLoop.main.run(until: .now + 0.1)
        XCTAssertEqual(session.entries, [])
        XCTAssertEqual([answers, you.starts, others.starts], [1, 1, 1])
    }

    func testFailedStartLeavesNothingRunning() {
        others.failure = MeetingError.systemAudioDenied
        assertThrows(.systemAudioDenied) { try start([.microphone, .systemAudio]) }
        XCTAssertEqual(you.starts, you.stops, "was schon lief, ist wieder aus")
        XCTAssertFalse(session.isStarting)
        XCTAssertEqual(session.startError, MeetingError.systemAudioDenied.errorDescription, "die Seite zeigt den Grund")

        others.failure = nil
        files.folderFailure = MeetingError.folderUnavailable("Steno Meetings")
        assertThrows(.folderUnavailable("Steno Meetings")) { try start([.microphone, .systemAudio]) }
        XCTAssertEqual([you.starts, others.starts], [you.stops, others.stops])
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.folder)
        XCTAssertEqual(files.writes.count, 0)
    }

    /// Mit einem Fehler von Core Audio kann niemand etwas anfangen – die Seite zeigt stattdessen einen Satz.
    func testSourceFailureGetsAPlainMessage() {
        others.failure = NSError(domain: NSOSStatusErrorDomain, code: -10851)
        assertThrows(.unavailable(.others)) { try start([.microphone, .systemAudio]) }
        others.failure = nil
        you.failure = Microphone.Failure.noInput
        assertThrows(.unavailable(.you)) { try start([.microphone, .systemAudio]) }
        XCTAssertEqual([you.starts, others.starts], [you.stops, others.stops])
    }

    /// Der Grund bleibt stehen, bis erneut gestartet wird – egal ob von der Meetings-Seite oder der Startseite.
    func testNextStartClearsTheLastError() throws {
        assertThrows(.noSource) { try start([]) }
        XCTAssertEqual(session.startError, MeetingError.noSource.errorDescription)
        try start(.microphone)
        XCTAssertNil(session.startError)
    }

    /// Ohne Freigabe liefert der Ton des Macs nur Stille. Das sagt die Seite gleich und nimmt es zurück, sobald die
    /// Freigabe da ist.
    func testMissingPermissionIsShownUntilItArrives() throws {
        others.lacksPermission = true
        try start([.microphone, .systemAudio])
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.problem, MeetingError.systemAudioDenied.errorDescription)

        others.lacksPermission = false
        wait(seconds: 3) { self.session.problem == nil }
        XCTAssertNil(session.problem)
    }

    func testRecordsBothSidesOnOneTimeline() throws {
        try start([.microphone, .systemAudio], title: "Planung")
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual([you.starts, others.starts], [1, 1])

        others.play(TestAudio.speech(6) + TestAudio.silence(1))
        you.play(TestAudio.silence(8) + TestAudio.speech(6) + TestAudio.silence(1))
        you.onLevel?(0.5)
        wait { self.session.entries.count == 2 && self.session.levels.you == 0.5 }
        XCTAssertEqual(speakers(), [.others, .you])
        XCTAssertEqual(session.entries[1].offset, 8 - 0.48, accuracy: 0.3)

        session.stop()
        XCTAssertEqual(session.state, .finishing)
        XCTAssertEqual([you.stops, others.stops], [1, 1])
        wait { self.session.state == .idle }
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.levels, MeetingLevels())
        let saved = try XCTUnwrap(files.writes.last)
        XCTAssertEqual(saved.entries, session.entries)
        XCTAssertEqual(saved.info.title, "Planung")
        XCTAssertGreaterThan(saved.info.duration, 0)
    }

    func testResultsArrivingOutOfOrderStaySorted() throws {
        var answers: [(String?) -> Void] = []
        session.transcription = { _, done in answers.append(done) }
        try start([.microphone, .systemAudio])
        others.play(TestAudio.speech(6) + TestAudio.silence(1))
        you.play(TestAudio.silence(8) + TestAudio.speech(6) + TestAudio.silence(1))
        wait { answers.count == 2 }
        answers[1]("Und dann machen wir es so.")
        answers[0]("Wer fängt an?")
        wait { self.session.entries.count == 2 }
        XCTAssertEqual(speakers(), [.others, .you])
    }

    func testStopTranscribesWhatWasStillOpen() throws {
        try start(.microphone)
        you.play(TestAudio.speech(2))
        RunLoop.main.run(until: .now + 0.1)
        XCTAssertEqual(session.entries, [], "noch keine Pause")
        session.stop()
        wait { self.session.state == .idle }
        XCTAssertEqual(speakers(), [.you])
    }

    func testChunksWaitWhileTheModelIsSwitched() throws {
        try start(.microphone)
        let whisper = session.transcription
        session.transcription = nil
        you.play(TestAudio.speech(6) + TestAudio.silence(1))
        RunLoop.main.run(until: .now + 0.1)
        XCTAssertEqual(session.entries, [])
        session.transcription = whisper
        wait { self.session.entries.count == 1 }

        // Was beim alten Modell noch anstand, kommt ohne Ergebnis zurück und geht ans neue.
        var closing: ((String?) -> Void)?
        session.transcription = { _, done in closing = done }
        you.play(TestAudio.speech(6) + TestAudio.silence(1))
        wait { closing != nil }
        session.transcription = whisper
        closing?(nil)
        wait { self.session.entries.count == 2 }

        // Beenden wartet, bis wieder ein Modell da ist.
        session.transcription = nil
        you.play(TestAudio.speech(6) + TestAudio.silence(1))
        session.stop()
        RunLoop.main.run(until: .now + 0.1)
        XCTAssertEqual(session.state, .finishing)
        session.transcription = whisper
        wait { self.session.state == .idle }
        XCTAssertEqual(session.entries.count, 3)
    }

    func testFallingBehindKeepsEverything() throws {
        var answers: [(String?) -> Void] = []
        session.transcription = { _, done in answers.append(done) }
        try start(.systemAudio)
        for _ in 0..<15 { others.play(TestAudio.speech(6) + TestAudio.silence(1)) }
        wait { answers.count == 15 }
        XCTAssertNotNil(session.problem)
        session.stop()
        for (index, answer) in answers.enumerated() { answer("Beitrag \(index)") }
        wait { self.session.state == .idle }
        XCTAssertNil(session.problem)
        XCTAssertEqual(session.entries.count, 15)
    }

    func testSourceThatFailsAfterSleepLeavesTheOther() throws {
        try start([.microphone, .systemAudio])
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        RunLoop.main.run(until: .now + 0.05)
        XCTAssertEqual([you.stops, others.stops], [1, 1])

        others.failure = MeetingError.systemAudioDenied
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        RunLoop.main.run(until: .now + 0.05)
        XCTAssertEqual(you.starts, 2)
        XCTAssertEqual(session.problem, L("Vom Ton des Macs kommt gerade nichts an."))

        you.play(TestAudio.speech(6) + TestAudio.silence(1))
        wait { self.session.entries.count == 1 }
        XCTAssertEqual(speakers(), [.you])
        XCTAssertEqual(session.state, .running)
    }

    func testQuittingWaitsOnlyBrieflyButSaves() throws {
        session.transcription = { _, _ in }  // Whisper antwortet nie
        try start(.microphone)
        you.play(TestAudio.speech(6) + TestAudio.silence(1))
        RunLoop.main.run(until: .now + 0.1)
        let begin = Date.now
        session.shutdown(waitingAtMost: 0.3)
        XCTAssertLessThan(Date.now.timeIntervalSince(begin), 1)
        XCTAssertEqual(session.state, .finishing)
        XCTAssertGreaterThan(try XCTUnwrap(files.writes.last).info.duration, 0)
    }

    // MARK: Notizen, Bilder, Speichern

    func testNotesMarksAndTasks() throws {
        session.addNote("ohne Meeting")
        XCTAssertEqual(session.entries, [])
        try start(.microphone)
        session.addNote("  ")
        session.addNote("! Angebot schicken")
        session.addNote("Budget klären")
        XCTAssertEqual(session.entries.map(\.kind), [.mark, .task("Angebot schicken"), .note("Budget klären")])
        XCTAssertTrue(session.entries.allSatisfy { $0.offset >= 0 && $0.offset < 1 })
    }

    func testPreviewNotesFitItsStartTime() {
        let preview = MeetingSession(state: .running, info: MeetingInfo(title: "", startedAt: .now - 60, sources: .microphone),
                                     microphone: FakeSource(), systemAudio: FakeSource())
        preview.addNote("Vorschau")
        XCTAssertEqual(preview.entries.first?.offset ?? 0, 60, accuracy: 1)
    }

    func testSameScreenshotOnlyOnce() throws {
        try start(.microphone)
        let red = image(.red)
        session.addImage(red)
        session.addImage(red)
        session.addImage(image(.blue))
        session.stop()
        wait { self.session.state == .idle }
        XCTAssertEqual(session.entries.map(\.kind), [.image("bild-1.png"), .image("bild-2.png")])
    }

    func testSavesRightAwayThenAtMostEveryOneAndAHalfSeconds() throws {
        try start(.microphone)
        wait { self.files.writes.count == 1 }
        XCTAssertEqual(files.writes.count, 1, "gleich beim Start")
        session.addNote("eins")
        session.addNote("zwei")
        session.setParticipants("Anna Meyer")
        RunLoop.main.run(until: .now + 1)
        XCTAssertEqual(files.writes.count, 1)
        wait { self.files.writes.count == 2 }
        let saved = try XCTUnwrap(files.writes.last)
        XCTAssertEqual(saved.entries.count, 2)
        XCTAssertEqual(saved.info.participants, "Anna Meyer")
        XCTAssertGreaterThan(saved.info.duration, 1, "die Dauer bis zum Speichern")
    }

    // MARK: Hilfen

    /// Startet wie die Meetings-Seite und wartet auf die Antwort; ein Fehler wird geworfen.
    private func start(_ sources: MeetingSources, title: String = "") throws {
        var answered = false
        var failure: Error?
        session.start(title: title, sources: sources) { error in
            failure = error
            answered = true
        }
        wait { answered }
        XCTAssertTrue(answered, "keine Antwort")
        if let failure { throw failure }
    }

    /// Lässt den Hauptthread laufen, bis die Bedingung gilt – im Normalfall höchstens zwei Sekunden.
    private func wait(seconds: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition(), Date.now < deadline { RunLoop.main.run(until: .now + 0.01) }
    }

    private func speakers() -> [Speaker] {
        session.entries.compactMap { entry in
            guard case .speech(let speaker, _) = entry.kind else { return nil }
            return speaker
        }
    }

    private func assertThrows(_ expected: MeetingError, _ body: () throws -> Void, line: UInt = #line) {
        XCTAssertThrowsError(try body(), line: line) { error in
            XCTAssertEqual((error as? MeetingError)?.errorDescription, expected.errorDescription, line: line)
        }
    }

    /// Wie aus der Zwischenablage: ein Bild aus Bilddaten.
    private func image(_ color: NSColor) -> NSImage {
        let drawn = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        return NSImage(data: drawn.tiffRepresentation!)!
    }
}

private final class FakeSource: AudioSource {
    var onSamples: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?
    var failure: Error?
    var lacksPermission = false
    /// Hält den Start auf wie die Frage nach der Freigabe.
    var waitsFor: DispatchSemaphore?
    private(set) var starts = 0
    private(set) var stops = 0

    func start() throws {
        waitsFor?.wait()
        if let failure { throw failure }
        starts += 1
    }

    func stopCapture() { stops += 1 }

    func play(_ samples: [Float]) { onSamples?(samples) }
}

/// Merkt sich, was geschrieben würde. Geschrieben wird auf einer Hintergrund-Queue, gelesen im Test.
private final class FakeFiling {
    var folderFailure: Error?
    private let lock = NSLock()
    private var written: [MeetingFile] = []
    private var images = 0

    var writes: [MeetingFile] { lock.withLock { written } }

    var filing: MeetingSession.Filing {
        MeetingSession.Filing(
            makeFolder: { [unowned self] _ in
                if let folderFailure { throw folderFailure }
                return URL(fileURLWithPath: "/nonexistent/Meeting", isDirectory: true)
            },
            write: { [unowned self] file, _ in lock.withLock { written.append(file) } },
            saveImage: { [unowned self] _, _, _ in
                lock.withLock {
                    images += 1
                    return "bild-\(images).png"
                }
            })
    }
}
