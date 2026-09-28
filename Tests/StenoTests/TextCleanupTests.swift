import XCTest
@testable import Steno

final class TextCleanupTests: XCTestCase {
    private let vocabulary = Vocabulary(words: ["Anna Meyer", "Kubernetes", "E-Mail", "Node.js"],
                                        replacements: [Replacement(von: "Mayor", zu: "Meyer")])

    private func clean(_ text: String, swiss: Bool = false) -> String {
        TextCleanup.apply(text, vocabulary, language: "de", swiss: swiss)
    }

    func testCorrectsSimilarSoundingNames() {
        XCTAssertEqual(clean("Ich heiße Anna Mayer."), "Ich heiße Anna Meyer.")
        XCTAssertEqual(clean("Herr Meyr hat angerufen"), "Herr Meyer hat angerufen")
        XCTAssertEqual(clean("Das läuft auf Kubernetis."), "Das läuft auf Kubernetes.")
    }

    func testJoinsSplitTerms() {
        XCTAssertEqual(clean("Schreib mir eine e mail."), "Schreib mir eine E-Mail.")
        XCTAssertEqual(clean("Das läuft mit node js."), "Das läuft mit Node.js.")
    }

    func testLeavesOtherWordsAlone() {
        XCTAssertEqual(clean("Andrea kommt auch."), "Andrea kommt auch.")
        XCTAssertEqual(clean("Summa cum laude bestanden."), "Summa cum laude bestanden.")
        XCTAssertEqual(clean("Mauers und Meiers bleiben."), "Mauers und Meiers bleiben.")
        XCTAssertEqual(clean("Wir brauchen Eier."), "Wir brauchen Eier.")
        XCTAssertEqual(clean("Sag Andreas. Meyer ist mein Name."), "Sag Andreas. Meyer ist mein Name.")
        XCTAssertEqual(clean("Die Untertitel von dem Film waren schlecht."), "Die Untertitel von dem Film waren schlecht.")
    }

    func testKeepsRealWords() {
        XCTAssertEqual(clean("Wir fahren ans Meer."), "Wir fahren ans Meer.")
        XCTAssertEqual(clean("Das sind zwei Meter."), "Das sind zwei Meter.")
        let names = Vocabulary(words: ["Karl", "Linda", "Paul"], replacements: [])
        XCTAssertEqual(TextCleanup.apply("Der Kerl sitzt unter der Linde.", names, language: "de"),
                       "Der Kerl sitzt unter der Linde.")
    }

    func testLeavesCommonWordsAlone() {
        let short = Vocabulary(words: ["Klein", "Lang", "Tim", "Mai", "€", "C++"], replacements: [])
        XCTAssertEqual(TextCleanup.apply("Wir brauchen einen kleinen Tisch, das dauert lange.", short, language: "de"),
                       "Wir brauchen einen kleinen Tisch, das dauert lange.")
        XCTAssertEqual(TextCleanup.apply("At the same time, the main reason is Vitamin C.", short, language: "en"),
                       "At the same time, the main reason is Vitamin C.")
        XCTAssertEqual(TextCleanup.apply("Er sagt, es geht.", short, language: "de"), "Er sagt, es geht.")
        XCTAssertEqual(TextCleanup.apply("That is Meyer’s car.", vocabulary, language: "en"), "That is Meyer’s car.")
        XCTAssertEqual(clean("Das läuft auf kubernetes."), "Das läuft auf Kubernetes.")
    }

    func testKeepsSubtitleSentencesInTheMiddle() {
        XCTAssertEqual(clean("Die Untertitel des ZDF sind schlecht."), "Die Untertitel des ZDF sind schlecht.")
    }

    func testKeepsFrenchSpacing() {
        XCTAssertEqual(TextCleanup.apply("Comment allez-vous ? Très bien !", vocabulary, language: "fr"),
                       "Comment allez-vous ? Très bien !")
    }

    func testLongTextStaysFast() {
        let long = String(repeating: "wir sprechen lange ohne punkt und komma ", count: 600)  // etwa 24 000 Zeichen
        let many = Vocabulary(words: (0..<100).map { "Begriff\($0)" } + ["Meyer"], replacements: [])
        let start = Date()
        _ = TextCleanup.apply(long, many, language: "de")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testKeepsEndings() {
        XCTAssertEqual(clean("Ich habe drei E-Mails bekommen."), "Ich habe drei E-Mails bekommen.")
        XCTAssertEqual(clean("Anna Meyers Vortrag war gut."), "Anna Meyers Vortrag war gut.")
        XCTAssertEqual(clean("Ich schreibe drei e mails."), "Ich schreibe drei E-Mails.")
    }

    func testRemovesWhisperHallucinations() {
        XCTAssertEqual(clean("[Musik] Hallo zusammen. Untertitel der Amara.org-Community"), "Hallo zusammen.")
        XCTAssertEqual(clean("Hallo. Untertitel im Auftrag des ZDF, 2021"), "Hallo.")
        XCTAssertEqual(clean("Danke. Untertitelung des ZDF, 2020"), "Danke.")
        XCTAssertEqual(clean("Tschüss. Copyright WDR 2021"), "Tschüss.")
    }

    func testRemovesRepeatedSentences() {
        XCTAssertEqual(clean("Willkommen bei VoiceOder. Willkommen bei VoiceOder. Willkommen bei VoiceOder."),
                       "Willkommen bei VoiceOder.")
        XCTAssertEqual(clean("Das passt so. Das passt so! Und weiter."), "Das passt so. Und weiter.")
        // Kurze Wiederholungen, Wiederholungen im Satz und Kommazahlen bleiben.
        XCTAssertEqual(clean("Ja. Ja. Test, test, test. Es sind 3.5 Prozent. Es sind 3.5 Prozent mehr."),
                       "Ja. Ja. Test, test, test. Es sind 3.5 Prozent. Es sind 3.5 Prozent mehr.")
    }

    func testFixedReplacements() {
        XCTAssertEqual(clean("Der Mayor hat angerufen."), "Der Meyer hat angerufen.")
    }

    func testSwissSpelling() {
        XCTAssertEqual(clean("Das ist groß.", swiss: true), "Das ist gross.")
        XCTAssertEqual(clean("Das ist groß."), "Das ist groß.")
    }
}
