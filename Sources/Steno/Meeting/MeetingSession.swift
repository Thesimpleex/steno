import AppKit

/// Ein Meeting, das gerade aufgenommen wird: Mikrofon und Ton des Macs werden in Abschnitte geschnitten,
/// mit Whisper umgewandelt und mit Zeitstempel in die Zeitleiste gelegt.
///
/// Die Quellen liefern auf Audio-Threads, geschnitten wird auf einer eigenen Queue, alles Sichtbare ändert sich auf dem
/// Hauptthread. Der Ton wird nie gespeichert und nur so lange gehalten, bis Whisper ihn gelesen hat.
final class MeetingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        /// Die Quellen sind gestoppt, die letzten Abschnitte werden noch umgewandelt.
        case finishing
    }

    /// Macht aus einem Abschnitt fertigen Text. nil als Ergebnis: Das Modell wurde geschlossen, bevor er dran war.
    typealias Transcription = (_ samples: [Float], _ completion: @escaping (String?) -> Void) -> Void

    /// Die Ablage. Nur `MeetingStore` fasst Dateien an; die Tests setzen Attrappen ein.
    struct Filing {
        var makeFolder: (MeetingInfo) throws -> URL = MeetingStore.makeFolder(for:)
        var write: (MeetingFile, URL) throws -> Void = MeetingStore.write(_:to:)
        var saveImage: (NSImage, TimeInterval, URL) throws -> String = MeetingStore.saveImage(_:at:in:)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var info = MeetingInfo(title: "", startedAt: .now, sources: []) { didSet { scheduleSave() } }
    @Published private(set) var entries: [MeetingEntry] = [] { didSet { scheduleSave() } }
    @Published private(set) var levels = MeetingLevels()
    /// Eine Meldung für die Oberfläche, etwa wenn während des Meetings eine Quelle ausfällt.
    @Published private(set) var problem: String?

    /// Ordner des laufenden oder zuletzt beendeten Meetings.
    private(set) var folder: URL?
    /// Das geladene Sprachmodell; AppDelegate setzt es, so wie es `Dictation` bekommt.
    var transcriber: Transcriber? {
        didSet { transcription = transcriber.map(Self.whisper) }
    }
    /// nil während eines Modellwechsels – so lange warten die Abschnitte. Die Tests setzen hier eine Attrappe ein.
    var transcription: Transcription? {
        didSet {
            generation += 1
            let held = waiting
            waiting = []
            held.forEach(send)
        }
    }

    private let microphone: AudioSource
    private let systemAudio: AudioSource
    private let filing: Filing
    private let work = DispatchQueue(label: "steno.meeting", qos: .userInitiated)
    private let storage = DispatchQueue(label: "steno.meeting.storage", qos: .utility)

    private var sources: [Speaker: AudioSource] = [:]
    /// Die Uhr beim Start; gesetzt, bevor eine Quelle läuft.
    private var origin: TimeInterval = 0
    private var waiting: [Piece] = []
    /// Abschnitte bei Whisper und Bilder, die gerade gespeichert werden.
    private var pending = 0
    /// Sekunden Ton, die bei Whisper liegen.
    private var backlog: TimeInterval = 0
    /// Zählt die Modellwechsel.
    private var generation = 0
    /// Nach `stop`: Es kommt kein Abschnitt mehr dazu.
    private var flushed = false
    /// Die Quellen starten gerade im Hintergrund.
    private var starting = false
    private var asleep = false
    private var saveWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var activity: NSObjectProtocol?
    // Nur auf `work`:
    private var tracks: [Speaker: Track] = [:]
    private var latest = MeetingLevels()
    private var nextLevels: TimeInterval = 0
    // Nur auf `storage`:
    private var lastImage: Int?

    /// Vorschaubilder und Tests geben einen fertigen Zustand vor, Tests auch Attrappen für Tonquellen und Ablage.
    init(state: State = .idle, info: MeetingInfo = MeetingInfo(title: "", startedAt: .now, sources: []),
         entries: [MeetingEntry] = [], microphone: AudioSource = Microphone(), systemAudio: AudioSource = SystemAudio(),
         filing: Filing = Filing()) {
        self.state = state
        self.info = info
        self.entries = entries
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.filing = filing
        origin = Self.clock() - Date.now.timeIntervalSince(info.startedAt)  // eine Notiz in der Vorschau passt zur Startzeit
        hook(microphone, as: .you)
        hook(systemAudio, as: .others)
    }

    /// Beginnt ein Meeting. Die Quellen starten im Hintergrund: Beim ersten Mal wartet der Ton des Macs, bis die Frage
    /// nach der Freigabe beantwortet ist. `done` kommt auf dem Hauptthread, mit dem Fehler, wenn Modell, Freigabe oder
    /// Ordner fehlen. Ein weiterer Aufruf, solange noch gestartet wird, bleibt ohne Wirkung und ohne Antwort.
    func start(title: String, sources wanted: MeetingSources, done: @escaping (Error?) -> Void) {
        guard !starting else { return }
        guard state == .idle else { return done(MeetingError.alreadyRunning) }
        guard transcription != nil else { return done(MeetingError.noModel) }
        guard !wanted.isEmpty else { return done(MeetingError.noSource) }
        var chosen: [Speaker: AudioSource] = [:]
        if wanted.contains(.microphone) {
            if let microphone = microphone as? Microphone {
                guard Microphone.authorized else { return done(MeetingError.microphoneDenied) }
                microphone.accumulates = false  // ein Meeting dauert Stunden; der Ton geht stückweise weiter
            }
            chosen[.you] = microphone
        }
        if wanted.contains(.systemAudio) { chosen[.others] = systemAudio }
        if saveWork != nil { save() }  // eine Änderung am vorigen Meeting gehört noch in dessen Ordner

        let info = MeetingInfo(title: title, startedAt: .now, sources: wanted)
        origin = Self.clock()
        starting = true
        DispatchQueue.global(qos: .userInitiated).async { [filing] in
            var started: [AudioSource] = []
            let result = Result {
                for (speaker, source) in chosen {
                    // Fehlt die Freigabe, sagt die Quelle es selbst; mit dem Fehler von Core Audio kann niemand etwas anfangen.
                    do { try source.start() } catch { throw error as? MeetingError ?? MeetingError.unavailable(speaker) }
                    started.append(source)
                }
                // Erst jetzt: Scheitert eine Quelle, bleibt kein leerer Ordner zurück.
                return try filing.makeFolder(info)
            }
            if case .failure = result { started.forEach { $0.stopCapture() } }
            DispatchQueue.main.async {
                self.starting = false
                do {
                    self.begin(info, sources: chosen, in: try result.get())
                    done(nil)
                } catch {
                    done(error)
                }
            }
        }
    }

    /// Die Quellen laufen, der Ordner steht. Erst ab hier zählt ihr Ton – was davor kam, etwa während macOS nach der
    /// Freigabe fragte, gehört noch zu keinem Meeting.
    private func begin(_ info: MeetingInfo, sources chosen: [Speaker: AudioSource], in folder: URL) {
        work.sync {
            tracks = chosen.mapValues { _ in Track() }
            latest = MeetingLevels()
            nextLevels = 0
        }
        self.folder = folder
        sources = chosen
        self.info = info
        entries = []
        problem = nil
        levels = MeetingLevels()
        backlog = 0
        asleep = false
        state = .running
        storage.async { self.lastImage = nil }
        save()
        observe()
        // Auch wenn niemand den Mac anfasst, soll er während des Meetings nicht einschlafen.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Steno schreibt ein Meeting mit")
    }

    func stop() {
        guard state == .running else { return }
        state = .finishing
        info.duration = elapsed
        stopObserving()
        sources.values.forEach { $0.stopCapture() }
        sources = [:]
        work.async {
            let tails = self.flushTracks()
            self.tracks = [:]
            DispatchQueue.main.async {
                self.levels = MeetingLevels()
                tails.forEach(self.send)
                self.flushed = true
                self.finishIfDone()
            }
        }
    }

    /// Beim Beenden der App: Meeting beenden und begrenzt warten, bis die letzten Abschnitte umgewandelt sind.
    /// Was dann noch fehlt, fehlt – gespeichert wird trotzdem.
    func shutdown(waitingAtMost seconds: TimeInterval = 5) {
        stop()
        let deadline = Date.now.addingTimeInterval(seconds)
        while state == .finishing, Date.now < deadline { RunLoop.main.run(until: .now + 0.05) }
        guard state == .finishing else { return }
        save()
        storage.sync {}
    }

    /// Text leer: Markierung. Beginnt er mit „!“: Aufgabe. Sonst Notiz.
    func addNote(_ text: String) {
        guard state == .running else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: MeetingEntry.Kind
        if text.isEmpty {
            kind = .mark
        } else if text.hasPrefix("!") {
            kind = .task(text.dropFirst().trimmingCharacters(in: .whitespaces))
        } else {
            kind = .note(text)
        }
        entries.insertSorted(MeetingEntry(offset: elapsed, kind: kind))
    }

    /// Ein Screenshot aus der Zwischenablage; er wird als PNG im Bilderordner abgelegt.
    func addImage(_ image: NSImage) {
        guard state == .running, let folder else { return }
        let offset = elapsed
        pending += 1
        storage.async {
            let name = self.store(image, at: offset, in: folder)
            DispatchQueue.main.async {
                self.pending -= 1
                if let name { self.entries.insertSorted(MeetingEntry(offset: offset, kind: .image(name))) }
                self.finishIfDone()
            }
        }
    }

    func remove(_ entry: MeetingEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    func rename(others name: String) { info.othersName = name }
    func setParticipants(_ text: String) { info.participants = text }

    // MARK: Ton

    private func hook(_ source: AudioSource, as speaker: Speaker) {
        source.onSamples = { [weak self] samples in
            guard let self else { return }
            let time = self.elapsed  // beim Liefern gemessen, nicht erst, wenn die Queue dazu kommt
            self.work.async { self.receive(samples, at: time, from: speaker) }
        }
        source.onLevel = { [weak self] level in
            guard let self else { return }
            let time = self.elapsed
            self.work.async { self.show(level, at: time, from: speaker) }
        }
    }

    /// Auf `work`.
    private func receive(_ samples: [Float], at time: TimeInterval, from speaker: Speaker) {
        guard let track = tracks[speaker] else { return }
        let recovered = track.stalls > 0
        let chunks = track.append(samples, at: time)
        guard recovered || !chunks.isEmpty else { return }
        DispatchQueue.main.async {
            if recovered, self.problem == Self.failure(of: speaker) { self.problem = nil }
            chunks.forEach { self.send(Piece(speaker: speaker, chunk: $0)) }
        }
    }

    /// Auf `work`. Höchstens 15-mal in der Sekunde, denn jede Änderung zeichnet die Seite neu.
    private func show(_ level: Float, at time: TimeInterval, from speaker: Speaker) {
        guard tracks[speaker] != nil else { return }
        if speaker == .you { latest.you = level } else { latest.others = level }
        guard time >= nextLevels else { return }
        nextLevels = time + 1.0 / 15
        let levels = latest
        DispatchQueue.main.async { self.levels = levels }
    }

    /// Auf `work`: die angefangenen Abschnitte aller Quellen abschließen.
    private func flushTracks() -> [Piece] {
        tracks.compactMap { speaker, track in track.flush().map { Piece(speaker: speaker, chunk: $0) } }
    }

    // MARK: Whisper

    /// Wie beim Diktat: das Wörterbuch als Hinweis für Whisper, danach die Nachbearbeitung – nur hinter jedem Diktat.
    private static func whisper(_ transcriber: Transcriber) -> Transcription {
        { samples, completion in
            let vocabulary = DictionaryStore.shared.vocabulary
            let language = SpeechLanguage.current
            transcriber.transcribeBackground(samples, prompt: vocabulary.whisperPrompt, language: language.whisperCode) { raw in
                completion(raw.map { TextCleanup.apply($0, vocabulary, language: language.whisperCode, swiss: language == .swissGerman) })
            }
        }
    }

    private func send(_ piece: Piece) {
        guard let transcription else { return hold(piece) }
        var piece = piece
        piece.generation = generation
        pending += 1
        backlog += piece.chunk.duration
        // Kommt Whisper nicht mit, bleibt alles liegen, bis es dran ist – nur Bescheid sagen.
        if backlog > 90, problem == nil { problem = Self.behind }
        transcription(piece.chunk.samples) { [weak self] text in
            DispatchQueue.main.async { self?.transcribed(piece, text) }
        }
    }

    private func transcribed(_ piece: Piece, _ text: String?) {
        pending -= 1
        backlog -= piece.chunk.duration
        if backlog < 30, problem == Self.behind { problem = nil }
        if let text {
            if !text.isEmpty { entries.addSpeech(text, by: piece.speaker, at: piece.chunk.offset) }
        } else if piece.generation == generation {
            hold(piece)  // dieses Modell ist geschlossen: aufs nächste warten
        } else {
            send(piece)  // das Modell wurde gewechselt, bevor der Abschnitt dran war
        }
        finishIfDone()
    }

    /// Kommt lange kein Modell, gehen die ältesten Abschnitte verloren, statt den Speicher zu füllen.
    private func hold(_ piece: Piece) {
        waiting.append(piece)
        while waiting.reduce(0, { $0 + $1.chunk.duration }) > 300 {
            waiting.removeFirst()
            problem = L("Kein Sprachmodell geladen – ein Teil des Meetings fehlt.")
        }
    }

    private static var behind: String { L("Die Umwandlung kommt nicht hinterher – der Text folgt etwas später.") }

    private func finishIfDone() {
        guard state == .finishing, flushed, pending == 0, waiting.isEmpty else { return }
        flushed = false
        save()
        storage.async {
            DispatchQueue.main.async {
                self.state = .idle
                if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity) }
                self.activity = nil
            }
        }
    }

    // MARK: Speichern

    /// Spätestens 1,5 s nach einer Änderung steht sie in meeting.json – so bleibt auch nach einem Absturz ein brauchbares
    /// Protokoll, ohne bei jedem Wort zu schreiben.
    private func scheduleSave() {
        guard folder != nil, saveWork == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func save() {
        saveWork?.cancel()
        saveWork = nil
        guard let folder else { return }
        var file = MeetingFile(info: info, entries: entries)
        if state == .running { file.info.duration = elapsed }
        storage.async { self.write(file, to: folder) }
    }

    /// Auf `storage`.
    private func write(_ file: MeetingFile, to folder: URL) {
        do {
            try filing.write(file, folder)
        } catch {
            DispatchQueue.main.async { self.problem = MeetingError.folderUnavailable(folder.lastPathComponent).errorDescription }
        }
    }

    /// Auf `storage`. Die Zwischenablage meldet dasselbe Bild gern mehrmals: gleich wie das letzte – nicht noch einmal.
    private func store(_ image: NSImage, at offset: TimeInterval, in folder: URL) -> String? {
        var hasher = Hasher()
        image.tiffRepresentation?.withUnsafeBytes { hasher.combine(bytes: $0) }  // `Data` selbst hasht nur 80 Bytes
        let hash = hasher.finalize()
        guard hash != lastImage else { return nil }
        do {
            let name = try filing.saveImage(image, offset, folder)
            lastImage = hash
            return name
        } catch {
            DispatchQueue.main.async { self.problem = MeetingError.folderUnavailable(folder.lastPathComponent).errorDescription }
            return nil
        }
    }

    // MARK: Ruhezustand und Ausfälle

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.pauseForSleep()
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.resumeAfterWake()
            },
        ]
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkSources() }
    }

    private func stopObserving() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Im Ruhezustand kommt ohnehin kein Ton: Quellen anhalten und umwandeln, was bis dahin gesagt wurde.
    private func pauseForSleep() {
        guard state == .running, !asleep else { return }
        asleep = true
        sources.values.forEach { $0.stopCapture() }
        work.async {
            let tails = self.flushTracks()
            DispatchQueue.main.async { tails.forEach(self.send) }
        }
    }

    private func resumeAfterWake() {
        guard state == .running, asleep else { return }
        asleep = false
        let now = elapsed
        work.async { self.tracks.values.forEach { $0.lastBuffer = now } }  // Zeit zum Anlaufen
        for (speaker, source) in sources {
            do { try source.start() } catch { problem = Self.failure(of: speaker) }
        }
    }

    /// Liefert eine Quelle fünf Sekunden lang nichts – etwa weil ein anderes Mikrofon angesteckt wurde –, wird sie neu
    /// gestartet, notfalls immer wieder. Die andere läuft derweil weiter; die Meldung verschwindet, sobald wieder Ton kommt.
    private func checkSources() {
        guard !asleep else { return }
        let now = elapsed
        work.async {
            let stalled = self.tracks.filter { now - $0.value.lastBuffer > 5 }
            guard !stalled.isEmpty else { return }
            for (speaker, track) in stalled {
                track.lastBuffer = now  // nächster Versuch frühestens in fünf Sekunden
                track.stalls += 1
                if speaker == .you { self.latest.you = 0 } else { self.latest.others = 0 }
            }
            let levels = self.latest
            let repeated = stalled.mapValues { $0.stalls > 1 }
            DispatchQueue.main.async {
                guard self.state == .running, !self.asleep else { return }
                self.levels = levels
                repeated.forEach { self.restart($0.key, repeated: $0.value) }
            }
        }
    }

    /// `repeated`: Der letzte Neustart hat nichts gebracht – dann Bescheid sagen und es weiter versuchen.
    private func restart(_ speaker: Speaker, repeated: Bool) {
        guard let source = sources[speaker] else { return }
        source.stopCapture()
        do {
            try source.start()
            if repeated { problem = Self.failure(of: speaker) }
        } catch {
            problem = Self.failure(of: speaker)
        }
    }

    private static func failure(of speaker: Speaker) -> String {
        speaker == .you ? L("Das Mikrofon liefert gerade keinen Ton.") : L("Vom Ton des Macs kommt gerade nichts an.")
    }

    /// Sekunden seit Beginn des Meetings.
    private var elapsed: TimeInterval { Self.clock() - origin }

    /// Läuft auch im Ruhezustand weiter und springt nicht, wenn jemand die Uhrzeit stellt – anders als `Date`.
    private static func clock() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
    }

    /// Ein Abschnitt auf dem Weg zu Whisper.
    private struct Piece {
        let speaker: Speaker
        let chunk: Chunker.Chunk
        var generation = 0  // mit welchem Modell er losgeschickt wurde
    }

    /// Was je Quelle auf `work` mitläuft.
    private final class Track {
        var lastBuffer: TimeInterval = 0
        var stalls = 0  // Neustarts seit dem letzten Puffer
        private var chunker: Chunker?

        /// Der erste Puffer legt fest, wo der Ton auf der gemeinsamen Uhr liegt – ebenso jeder nach einer Lücke im
        /// Strom (Ruhezustand, Neustart der Quelle).
        func append(_ samples: [Float], at time: TimeInterval) -> [Chunker.Chunk] {
            lastBuffer = time
            stalls = 0
            let begin = time - Double(samples.count) / Chunker.sampleRate
            var chunks: [Chunker.Chunk] = []
            if chunker == nil || begin - chunker!.position > 1 {
                if let tail = flush() { chunks.append(tail) }
                chunker = Chunker(offset: max(0, begin))
            }
            return chunks + chunker!.append(samples)
        }

        func flush() -> Chunker.Chunk? {
            defer { chunker = nil }
            return chunker?.flush()
        }
    }
}

extension Array where Element == MeetingEntry {
    /// Die Zeitleiste bleibt nach der Zeit sortiert; bei gleicher Zeit kommt das Neue dahinter.
    mutating func insertSorted(_ entry: MeetingEntry) {
        insert(entry, at: firstIndex { $0.offset > entry.offset } ?? endIndex)
    }

    /// Gesprochenes einsortieren – die Abschnitte beider Quellen werden nicht in ihrer Reihenfolge fertig.
    /// Ohne Kopfhörer hört das Mikrofon die anderen mit: Deckt sich ein eigener Beitrag fast mit einem der anderen aus
    /// denselben Sekunden, ist er deren Echo und fällt weg, egal welcher zuerst fertig wird.
    mutating func addSpeech(_ text: String, by speaker: Speaker, at offset: TimeInterval) {
        let entry = MeetingEntry(offset: offset, kind: .speech(speaker, text))
        if speaker == .you {
            if contains(where: { Self.isEcho(entry, of: $0) }) { return }
        } else {
            removeAll { Self.isEcho($0, of: entry) }
        }
        insertSorted(entry)
    }

    /// Kurze Antworten („Ja, genau.“) sagen oft beide – die gelten nie als Echo.
    private static func isEcho(_ yours: MeetingEntry, of theirs: MeetingEntry) -> Bool {
        guard case .speech(.you, let mine) = yours.kind, case .speech(.others, let other) = theirs.kind,
              abs(yours.offset - theirs.offset) <= 15 else { return false }
        func words(_ text: String) -> [Substring] { TextCleanup.fold(text).split { !$0.isLetter && !$0.isNumber } }
        let spoken = words(mine)
        return spoken.count >= 4
            && TextCleanup.similarity(spoken.joined(separator: " "), words(other).joined(separator: " ")) >= 0.8
    }
}
