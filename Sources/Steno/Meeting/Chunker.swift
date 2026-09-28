import Foundation

/// Schneidet den Ton einer Quelle an Sprechpausen in Abschnitte für Whisper.
///
/// Gemessen wird in Stücken von 30 ms: Sprache ist, was deutlich lauter ist als das Grundrauschen, also als das
/// leiseste Stück der letzten drei Sekunden. So passt sich die Schwelle an Lüfter, Straße oder eine rauschende Leitung an.
struct Chunker {
    struct Chunk: Equatable {
        /// Sekunden seit Beginn des Meetings.
        var offset: TimeInterval
        var samples: [Float]

        var duration: TimeInterval { Double(samples.count) / Chunker.sampleRate }
    }

    static let sampleRate = 16_000.0

    private static let frame = 480            // Samples je Stück; alle Längen darunter in Stücken
    private static let lead = 16              // 0,48 s vor dem ersten Wort: Whisper hört den Anfang mit
    private static let pause = 24             // 0,72 s Pause schließen den Abschnitt, sobald …
    private static let enoughSpeech = 134     // … gut 4 s gesprochen wurden – kürzere Stücke versteht Whisper schlechter
    private static let longPause = 67         // 2 s schließen ihn immer: Ein kurzes „Ja.“ soll nicht am nächsten Beitrag hängen
    private static let longest = 666          // 20 s: So wartet ein Diktat nie länger als einen Abschnitt
    private static let leastSpeech = 7        // weniger als 0,2 s Sprache ist ein Klicken oder Rascheln
    private static let noiseWindow = 100      // 3 s
    private static let margin: Float = 10     // dB über dem Rauschen …
    private static let quietest: Float = -65  // … aber nie unter −55 dB, sonst zählte bei digitaler Stille jedes Rauschen

    /// Wohin das nächste Sample gehört, in Sekunden seit Beginn des Meetings.
    var position: TimeInterval { time(of: received) }

    private let anchor: TimeInterval
    private var received = 0
    private var start = 0               // Nummer des ersten Samples im angefangenen Abschnitt
    private var samples: [Float] = []   // der angefangene Abschnitt, aus ganzen Stücken
    private var voiced: [Bool] = []     // je Stück: Sprache?
    private var spoken = 0              // Stücke mit Sprache im angefangenen Abschnitt
    private var rest: [Float] = []      // noch kein ganzes Stück
    private var levels: [Float] = []    // Pegel der letzten Stücke in dB

    /// `offset`: wo das erste Sample liegt, in Sekunden seit Beginn des Meetings.
    init(offset: TimeInterval) {
        anchor = offset
    }

    /// Nimmt neuen Ton an und gibt zurück, was dabei fertig wurde.
    mutating func append(_ new: [Float]) -> [Chunk] {
        received += new.count
        rest += new
        var chunks: [Chunk] = []
        var used = 0
        while rest.count - used >= Self.frame {
            if let chunk = add(rest[used..<used + Self.frame]) { chunks.append(chunk) }
            used += Self.frame
        }
        rest.removeFirst(used)
        return chunks
    }

    /// Schließt den angefangenen Abschnitt ab, etwa am Ende der Aufnahme.
    mutating func flush() -> Chunk? {
        let chunk = spoken >= Self.leastSpeech ? Chunk(offset: time(of: start), samples: samples + rest) : nil
        start = received
        samples = []
        voiced = []
        spoken = 0
        rest = []
        return chunk
    }

    private mutating func add(_ frame: ArraySlice<Float>) -> Chunk? {
        let speech = isSpeech(frame)
        samples += frame
        voiced.append(speech)
        if speech { spoken += 1 }
        guard spoken > 0 else {
            keepLead()
            return nil
        }
        let quiet = voiced.reversed().prefix { !$0 }.count
        if quiet >= Self.longPause || (quiet >= Self.pause && spoken >= Self.enoughSpeech) { return cut(at: voiced.count) }
        if voiced.count >= Self.longest { return cut(at: cutPoint()) }
        return nil
    }

    private mutating func isSpeech(_ frame: ArraySlice<Float>) -> Bool {
        let power = frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)
        let level = 10 * log10(power + 1e-10)
        levels.append(level)
        if levels.count > Self.noiseWindow { levels.removeFirst() }
        return level > max(levels.min()!, Self.quietest) + Self.margin
    }

    /// Ein zu langer Abschnitt wird mitten in der längsten Pause der letzten 10 s geschnitten, damit kein Wort
    /// zerfällt – nur ohne jede Pause am Ende.
    private func cutPoint() -> Int {
        var best = (length: 0, end: voiced.count)
        var run = 0
        for i in voiced.count / 2..<voiced.count {
            run = voiced[i] ? 0 : run + 1
            if run > 0, run >= best.length { best = (run, i + 1) }
        }
        return best.end - best.length / 2
    }

    /// Gibt die ersten Stücke als Abschnitt heraus; ohne Sprache darin fallen sie weg.
    private mutating func cut(at frames: Int) -> Chunk? {
        let chunk = Chunk(offset: time(of: start), samples: Array(samples[..<(frames * Self.frame)]))
        let before = spoken
        drop(frames)
        keepLead()
        return before - spoken >= Self.leastSpeech ? chunk : nil
    }

    /// Vor dem ersten Wort bleibt nur ein kurzes Stück Stille – der Abschnitt beginnt, wo gesprochen wird.
    private mutating func keepLead() {
        if spoken == 0, voiced.count > Self.lead { drop(voiced.count - Self.lead) }
    }

    private mutating func drop(_ frames: Int) {
        spoken -= voiced[..<frames].filter { $0 }.count
        voiced.removeFirst(frames)
        samples.removeFirst(frames * Self.frame)
        start += frames * Self.frame
    }

    private func time(of sample: Int) -> TimeInterval {
        anchor + Double(sample) / Self.sampleRate
    }
}
