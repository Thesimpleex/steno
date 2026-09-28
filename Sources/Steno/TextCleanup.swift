import AppKit
import NaturalLanguage

/// Nachbearbeitung ohne LLM: Whisper-Artefakte entfernen, eigene Wörter richtig schreiben
/// (auch wenn Whisper sie verhört hat), feste Ersetzungen anwenden.
enum TextCleanup {
    /// Rechtschreibprüfung und Namenserkennung von macOS vertragen keine gleichzeitigen Aufrufe: Diktat und Meeting
    /// bearbeiten ihren Text deshalb nacheinander auf dieser einen Queue.
    static let queue = DispatchQueue(label: "steno.cleanup", qos: .userInitiated)

    /// `language`: Whisper-Kürzel der Diktiersprache („de“, „en“ …, „auto“).
    static func apply(_ raw: String, _ vocabulary: Vocabulary, language: String = "auto", swiss: Bool = false) -> String {
        var text = removeArtifacts(raw, language: language)
        if swiss {  // Schweizer Rechtschreibung kennt kein ß
            text = text.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ẞ", with: "SS")
        }
        text = correctWords(text, vocabulary.words, language: language)
        text = replace(text, vocabulary.replacements)
        return text
    }

    // MARK: Artefakte

    /// Geräuschmarken und die typischen Untertitel-Halluzinationen aus Whispers Trainingsdaten.
    /// Die Abspann-Zeilen gelten nur am Ende des Texts – so bleibt „Die Untertitel des ZDF sind schlecht.“ stehen.
    private static let artifacts: [NSRegularExpression] = [
        #"\[[^\]]*\]"#,
        #"\((?:Musik|Applaus|Lachen|Stille|music|applause)\)"#,
        #"\*[^*]{1,30}\*"#,
        #"Untertitel(?:ung)?(?: im Auftrag)? de[sr] (?:ZDF|WDR|SWR|BR|NDR|MDR|ARD|HR|SR|RBB|ORF|SRF)(?:,? (?:für funk,? )?\d{4})?[.!]?\s*$"#,
        #"(?:©|Copyright)\s*(?:ZDF|WDR|SWR|BR|NDR|MDR|ARD|HR|SR|RBB|ORF|SRF)(?:,?\s*\d{4})?[.!]?\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    /// Nur prüfen, wenn „amara.org“ vorkommt: Das Muster wäre auf langen Texten ohne Satzzeichen sehr langsam.
    private static let amara = try! NSRegularExpression(pattern: #"[^.!?]*Amara\.org\S*[^.!?]*[.!?]?"#, options: .caseInsensitive)

    private static let spaces = try! NSRegularExpression(pattern: #"\s+"#)
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([.,!?;:])"#)
    /// Im Französischen steht vor ! ? ; : ein Leerzeichen – dort nur vor Punkt und Komma entfernen.
    private static let spaceBeforePeriod = try! NSRegularExpression(pattern: #"\s+([.,])"#)

    static func removeArtifacts(_ raw: String, language: String = "auto") -> String {
        var text = raw
        func strip(_ regex: NSRegularExpression, _ template: String = "") {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        if text.range(of: "amara.org", options: .caseInsensitive) != nil { strip(amara) }
        artifacts.forEach { strip($0) }
        strip(spaces, " ")
        strip(language == "fr" ? spaceBeforePeriod : spaceBeforePunctuation, "$1")
        return removeRepeats(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?…]+(?:\s+|$)"#)

    /// Hängt Whisper in einer Schleife, steht derselbe Satz mehrmals hintereinander da: nur einmal behalten.
    /// Kurze Sätze („Ja. Ja.“) bleiben, wie sie sind.
    static func removeRepeats(_ text: String) -> String {
        let whole = text as NSString
        var sentences: [String] = []
        var start = 0
        for match in sentenceEnd.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            let end = match.range.location + match.range.length
            sentences.append(whole.substring(with: NSRange(location: start, length: end - start)))
            start = end
        }
        if start < whole.length { sentences.append(whole.substring(from: start)) }

        var result = ""
        var previous = ""
        for sentence in sentences {
            let words = sentence.lowercased().split { !$0.isLetter && !$0.isNumber }
            let key = words.joined(separator: " ")
            if words.count >= 3, key == previous { continue }
            previous = key
            result += sentence
        }
        return result
    }

    // MARK: Eigene Wörter

    private struct Term {
        let spelling: String
        let words: Int
        let key: String       // klein, ohne Akzente
        let sound: String     // Kölner Phonetik
        let strict: Bool      // Teilwort eines Namens: nur bei sehr hoher Ähnlichkeit
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’]\p{L}+)?"#)

    private static func tokens(_ text: String) -> [Range<String.Index>] {
        wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    static func correctWords(_ text: String, _ words: [String], language: String = "auto") -> String {
        let terms = makeTerms(words)
        guard !terms.isEmpty else { return text }
        let tokens = tokens(text)
        let firstLetters = tokens.map { fold(String(text[$0])).first }
        var names: [Range<String.Index>]?  // erst berechnen, wenn es gebraucht wird

        var claimed = Set<Int>()
        var edits: [(Range<String.Index>, String)] = []
        for term in terms where tokens.count >= term.words {
            for start in 0...(tokens.count - term.words) {
                // Schneller Vorfilter: Alle Treffer beginnen mit demselben Buchstaben wie der Eintrag.
                guard firstLetters[start] == term.key.first else { continue }
                let window = start..<(start + term.words)
                guard !window.contains(where: claimed.contains) else { continue }
                // Zwischen den Teilen nur kurze Trenner („E-Mail“, „Node.js“, Leerzeichen), kein Satzende.
                let gapsFit = window.dropLast().allSatisfy { i in
                    let gap = text[tokens[i].upperBound..<tokens[i + 1].lowerBound]
                    return gap.count <= 2 && !gap.contains(where: \.isNewline) && !(gap.count == 2 && gap.first != " " && gap.last == " ")
                }
                let span = tokens[window.lowerBound].lowerBound..<tokens[window.upperBound - 1].upperBound
                let candidate = String(text[span])
                guard gapsFit, let match = match(candidate, term) else { continue }
                var spelling = term.spelling
                switch match {
                case .exact, .joined: break
                case .inflected(let ending), .joinedInflected(let ending): spelling += ending
                case .similar: break
                }
                if candidate == spelling { claimed.formUnion(window); continue }
                // Echte Wörter bleiben stehen: „klein“ wird nicht zu „Klein“, „Meer“ nicht zu „Meyer“ –
                // außer der Satz zeigt, dass hier ein Name gemeint ist. Zusammengeschriebenes („e mail“) gilt immer.
                if match.checksWords {
                    let found = names ?? nameRanges(in: text, language: language)
                    names = found
                    let isName = found.contains { $0.overlaps(span) }
                    if !isName, window.allSatisfy({ isKnownWord(String(text[tokens[$0]]), language: language) }) { continue }
                }
                claimed.formUnion(window)
                edits.append((span, spelling))
            }
        }

        var result = text
        for (range, spelling) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            result.replaceSubrange(range, with: spelling)
        }
        return result
    }

    private static func makeTerms(_ words: [String]) -> [Term] {
        var seen = Set<String>()
        var terms: [Term] = []
        func add(_ raw: String, strict: Bool) {
            let spelling = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = fold(spelling)
            guard spelling.contains(where: { $0.isLetter || $0.isNumber }), seen.insert(key).inserted else { return }
            terms.append(Term(spelling: spelling, words: max(1, tokens(spelling).count),
                              key: key, sound: koelnerPhonetik(spelling), strict: strict))
        }
        words.forEach { add($0, strict: false) }
        // „Meyer“ aus „Anna Meyer“ auch einzeln erkennen
        for word in words where word.contains(" ") {
            word.split(separator: " ").filter { $0.count >= 5 }.forEach { add(String($0), strict: true) }
        }
        return terms.sorted { $0.words > $1.words }
    }

    private enum Match {
        case exact                      // gleich, bis auf Groß-/Kleinschreibung und Akzente
        case joined                     // nur Leerzeichen, Bindestrich oder Punkt anders: „e mail“ → „E-Mail“
        case inflected(String)          // mit Endung: „Meyers“, „Meyer’s“ – Endung bleibt
        case joinedInflected(String)    // beides: „e mails“ → „E-Mails“
        case similar                    // ähnlich geschrieben oder gesprochen: „Meyr“ → „Meyer“

        /// Gilt die Prüfung, ob hier ein echtes Wort steht? Beim Zusammenschreiben nicht.
        var checksWords: Bool {
            switch self {
            case .joined, .joinedInflected: return false
            default: return true
            }
        }
    }

    /// Endungen, die an einem Eintrag hängen dürfen (erst ab vier Buchstaben im Eintrag).
    private static let endings = ["ern", "en", "er", "es", "ns", "e", "n", "s"]
    private static let separators = try! NSRegularExpression(pattern: #"(?<=[\p{L}\p{N}])[ .\-](?=[\p{L}\p{N}])"#)

    /// Leerzeichen, Bindestriche und Punkte zwischen Buchstaben weglassen – andere Zeichen („C++“) bleiben.
    private static func joinedKey(_ key: String) -> String {
        separators.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "")
    }

    private static func match(_ candidate: String, _ term: Term) -> Match? {
        let key = fold(candidate)
        if key == term.key { return .exact }
        if ["’s", "'s"].contains(where: { key == term.key + $0 }) { return .inflected(String(candidate.suffix(2))) }
        let joined = joinedKey(key), termJoined = joinedKey(term.key)
        let separated = joined != key || termJoined != term.key
        if joined == termJoined { return separated ? .joined : .exact }
        if termJoined.count >= 4, joined.count > termJoined.count, joined.hasPrefix(termJoined) {
            let ending = String(joined.dropFirst(termJoined.count))
            if endings.contains(ending) {
                let original = String(candidate.suffix(ending.count))
                return joined != key ? .joinedInflected(original) : .inflected(original)
            }
        }
        // Gleicher Anfangsbuchstabe ist Pflicht: sonst würde aus „Eier“ „Meier“.
        guard term.key.count >= 4, key.count >= 3, key.first == term.key.first else { return nil }
        let similarity = similarity(key, term.key)
        guard similarity >= 0.8 || (!term.strict && similarity >= 0.65 && koelnerPhonetik(candidate) == term.sound) else { return nil }
        return .similar
    }

    /// Steht das Wort so im Wörterbuch von macOS? Bei „automatisch“ zählt jede der fünf Sprachen.
    private static func isKnownWord(_ word: String, language: String) -> Bool {
        let checker = NSSpellChecker.shared
        let languages = language == "auto" ? ["de", "en", "fr", "it", "es"] : [language]
        return languages.contains { code in
            checker.availableLanguages.contains(code) && checker.checkSpelling(
                of: word, startingAt: 0, language: code, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
    }

    /// Wo im Satz Namen stehen (Personen, Orte, Firmen), laut der Spracherkennung von macOS.
    private static func nameRanges(in text: String, language: String) -> [Range<String.Index>] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        if language != "auto" { tagger.setLanguage(NLLanguage(rawValue: language), range: text.startIndex..<text.endIndex) }
        var ranges: [Range<String.Index>] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) { ranges.append(range) }
            return true
        }
        return ranges
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    /// 1 − Levenshtein-Abstand / Länge des längeren Worts.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var previous = Array(0...y.count)
        var current = previous
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// Kölner Phonetik: gleicher Code heißt, es klingt im Deutschen ähnlich („Meyer“ = „Maier“ = „Mayer“ = 67).
    static func koelnerPhonetik(_ input: String) -> String {
        let letters = Array(fold(input).replacingOccurrences(of: "ß", with: "s").filter(\.isLetter))
        var digits: [Character] = []
        for (i, c) in letters.enumerated() {
            let prev = i > 0 ? letters[i - 1] : nil
            let next = i + 1 < letters.count ? letters[i + 1] : nil
            func followedBy(_ set: String) -> Bool { next.map(set.contains) ?? false }
            switch c {
            case "a", "e", "i", "j", "o", "u", "y": digits.append("0")
            case "b": digits.append("1")
            case "p": digits.append(followedBy("h") ? "3" : "1")
            case "d", "t": digits.append(followedBy("csz") ? "8" : "2")
            case "f", "v", "w": digits.append("3")
            case "g", "k", "q": digits.append("4")
            case "c":
                if i == 0 { digits.append(followedBy("ahkloqrux") ? "4" : "8") }
                else if let p = prev, "sz".contains(p) { digits.append("8") }
                else { digits.append(followedBy("ahkoqux") ? "4" : "8") }
            case "x": digits.append(contentsOf: (prev.map("ckq".contains) ?? false) ? "8" : "48")
            case "l": digits.append("5")
            case "m", "n": digits.append("6")
            case "r": digits.append("7")
            case "s", "z": digits.append("8")
            default: break
            }
        }
        var code = ""
        for (i, d) in digits.enumerated() where d != digits[safe: i - 1] && (d != "0" || i == 0) {
            code.append(d)
        }
        return code
    }

    // MARK: Feste Ersetzungen

    static func replace(_ text: String, _ replacements: [Replacement]) -> String {
        replacements.reduce(text) { text, r in
            let from = r.von.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, let regex = try? NSRegularExpression(
                pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: from) + #"(?![\p{L}\p{N}])"#,
                options: .caseInsensitive) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: r.zu))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
