import XCTest
@testable import Steno

final class MeetingMarkdownTests: XCTestCase {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    /// 28. September 2026, 14:30 Uhr in Berlin.
    private let start = ISO8601DateFormatter().date(from: "2026-09-28T12:30:00Z")!

    private func info(title: String = "Projektbesprechung", participants: String = "", othersName: String = "") -> MeetingInfo {
        MeetingInfo(title: title, startedAt: start, duration: 3930, participants: participants, othersName: othersName,
                    sources: [.microphone, .systemAudio])
    }

    private func render(_ info: MeetingInfo, _ entries: [MeetingEntry], locale: String = "de_DE") -> String {
        MeetingMarkdown.render(MeetingFile(info: info, entries: entries), locale: Locale(identifier: locale), timeZone: berlin)
    }

    private func speech(_ offset: TimeInterval, _ speaker: Speaker, _ text: String) -> MeetingEntry {
        MeetingEntry(offset: offset, kind: .speech(speaker, text))
    }

    private func entry(_ offset: TimeInterval, _ kind: MeetingEntry.Kind) -> MeetingEntry {
        MeetingEntry(offset: offset, kind: kind)
    }

    /// Die Zeilen unter „## Verlauf“.
    private func timeline(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").drop { $0 != "## Verlauf" }.dropFirst().map { $0.trimmingCharacters(in: .newlines) }
    }

    func testFullProtocol() {
        let text = render(info(participants: "Anna Meyer, Ben Weber", othersName: "Herr Meier"), [
            speech(12, .you, "Guten Morgen zusammen."),
            speech(15, .you, "Ich habe die Unterlagen dabei."),
            speech(20, .others, "Guten Morgen. Wollen wir mit dem Budget anfangen?"),
            entry(760, .task("Angebot an Herrn Meier schicken")),
            entry(775, .note("Preis für Variante B noch prüfen")),
            entry(782, .mark),
            entry(790, .image("13-10.png")),
            speech(820, .you, "Das schaue ich mir an."),
            entry(2465, .task("Termin für die Abnahme festlegen")),
        ])
        XCTAssertEqual(text, """
            # Projektbesprechung

            Montag, 28. September 2026 · Dauer 1:05:30 · Anna Meyer, Ben Weber

            ## Aufgaben

            - [ ] 12:40 Angebot an Herrn Meier schicken
            - [ ] 41:05 Termin für die Abnahme festlegen

            ## Verlauf

            **0:12 Du:** Guten Morgen zusammen. Ich habe die Unterlagen dabei.

            **0:20 Herr Meier:** Guten Morgen. Wollen wir mit dem Budget anfangen?

            **12:55 Notiz:** Preis für Variante B noch prüfen

            **13:02 Markierung**

            ![Bild 13:10](bilder/13-10.png)

            **13:40 Du:** Das schaue ich mir an.

            """)
    }

    func testLeavesOutWhatIsMissing() {
        XCTAssertEqual(render(info(title: " \n "), [speech(5, .others, "Hallo.")]), """
            # Meeting

            Montag, 28. September 2026 · Dauer 1:05:30

            ## Verlauf

            **0:05 Andere:** Hallo.

            """)
    }

    func testJoinsSpeechOfOneSpeakerWithinAFewSeconds() {
        let text = render(info(), [speech(10, .you, "Eins."), speech(14, .you, "Zwei."), speech(19, .you, "Drei."),
                                   speech(40, .you, "Vier.")])
        XCTAssertEqual(timeline(text), ["**0:10 Du:** Eins. Zwei. Drei.", "**0:40 Du:** Vier."])
    }

    func testOtherEntriesEndAParagraph() {
        let text = render(info(), [speech(10, .you, "Eins."), speech(11, .others, "Zwei."), speech(12, .you, "Drei."),
                                   entry(13, .note("Vier")), speech(14, .you, "Fünf."), entry(15, .mark), speech(16, .you, "Sechs.")])
        XCTAssertEqual(timeline(text), ["**0:10 Du:** Eins.", "**0:11 Andere:** Zwei.", "**0:12 Du:** Drei.", "**0:13 Notiz:** Vier",
                                        "**0:14 Du:** Fünf.", "**0:15 Markierung**", "**0:16 Du:** Sechs."])
    }

    func testTasksAreListedOnlyOnTop() {
        let text = render(info(), [speech(10, .you, "Eins."), entry(11, .task("Aufgabe")), speech(12, .you, "Zwei.")])
        XCTAssertEqual(timeline(text), ["**0:10 Du:** Eins. Zwei."])
        XCTAssertTrue(text.contains("- [ ] 0:11 Aufgabe\n"))
    }

    func testSortsEntriesByTime() {
        let text = render(info(), [speech(30, .you, "Spät."), entry(10, .note("Früh")), entry(20, .mark), speech(20.5, .others, "Mitte.")])
        XCTAssertEqual(timeline(text), ["**0:10 Notiz:** Früh", "**0:20 Markierung**", "**0:20 Andere:** Mitte.", "**0:30 Du:** Spät."])
    }

    func testKeepsEveryEntryOnOneLine() {
        let text = render(info(title: "Zeile eins\n# Zeile zwei"), [entry(5, .note("Erste\n\n- Zweite\r\n1. Dritte"))])
        XCTAssertTrue(text.hasPrefix("# Zeile eins # Zeile zwei\n"))
        XCTAssertEqual(timeline(text), ["**0:05 Notiz:** Erste - Zweite 1. Dritte"])
    }

    func testDateFollowsLanguageAndTimeZone() {
        XCTAssertTrue(render(info(), [], locale: "en_US").contains("Monday, September 28, 2026 · Dauer 1:05:30"))
        let night = MeetingInfo(title: "Spät", startedAt: ISO8601DateFormatter().date(from: "2026-09-28T22:30:00Z")!, sources: [])
        XCTAssertTrue(render(night, []).contains("Dienstag, 29. September 2026"))
    }

    func testTimestamps() {
        XCTAssertEqual(MeetingMarkdown.timestamp(0), "0:00")
        XCTAssertEqual(MeetingMarkdown.timestamp(59.9), "0:59")
        XCTAssertEqual(MeetingMarkdown.timestamp(60), "1:00")
        XCTAssertEqual(MeetingMarkdown.timestamp(3599), "59:59")
        XCTAssertEqual(MeetingMarkdown.timestamp(3600), "1:00:00")
        XCTAssertEqual(MeetingMarkdown.timestamp(3930), "1:05:30")
        XCTAssertEqual(MeetingMarkdown.timestamp(36_000), "10:00:00")
    }

    func testDamagedNumbersDoNotCrash() {
        XCTAssertEqual(MeetingMarkdown.timestamp(-5), "0:00")
        XCTAssertEqual(MeetingMarkdown.timestamp(.nan), "0:00")
        XCTAssertEqual(MeetingMarkdown.timestamp(-.infinity), "0:00")
        XCTAssertEqual(MeetingMarkdown.timestamp(1e300), "0:00")
        var broken = info()
        broken.duration = .infinity
        XCTAssertTrue(render(broken, [speech(1e300, .you, "Weit weg."), speech(-3, .others, "Davor.")]).contains("**0:00 Andere:** Davor."))
    }
}
