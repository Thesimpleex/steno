import AppKit
import Carbon.HIToolbox

/// Der ganze Ablauf: Taste → Aufnahme → Whisper → Nachbearbeitung → einfügen oder an der Notch zeigen.
///
/// - Taste (Standard ⌥) halten: Aufnahme läuft, bis sie losgelassen wird.
/// - Zweimal tippen: freihändig, bis noch einmal getippt wird. Esc bricht immer ab.
/// - Return während der Aufnahme: nach dem Einfügen abschicken.
final class Dictation {
    private enum Mode { case idle, holding, handsFree }

    var transcriber: Transcriber? {
        didSet {
            // Wurde während eines Modellwechsels diktiert, jetzt nachholen.
            if transcriber != nil, let queued = queuedAudio {
                queuedAudio = nil
                transcribe(queued.samples, send: queued.send)
            }
        }
    }
    var notReadyReason = ""
    var hotKey = HotKey.leftOption
    var onRecordingChanged: ((Bool) -> Void)?
    /// Nur im Speicher – auch wenn der Verlauf ausgeschaltet ist, geht ⌃⌥V.
    private(set) var lastText: String?

    let overlay = NotchOverlay()
    private let microphone = Microphone()
    private let media = MediaPause()

    private var mode = Mode.idle { didSet { onRecordingChanged?(mode != .idle) } }
    // Tastenzeiten als Systemlaufzeit, so wie der Tastatur-Thread sie gemessen hat.
    private var pressedAt: TimeInterval = 0
    private var lastTap: TimeInterval?
    private var chordInPress = false
    private var startedAt = Date.distantPast
    /// Nach Esc bleibt die Aufnahme 3 s zum Fortsetzen liegen – falls der Abbruch ein Versehen war.
    private var resumable: (samples: [Float], duration: TimeInterval)?
    private var resumed: (samples: [Float], duration: TimeInterval)?
    /// Kam fertig, während schon die nächste Aufnahme lief – wird danach gezeigt.
    private var pendingResult: String?
    private var lastInsertion: (date: Date, app: String?)?
    private var pendingStart: DispatchWorkItem?
    private var pendingMediaPause: DispatchWorkItem?
    private var recordingLimit: DispatchWorkItem?
    private var resumeExpiry: DispatchWorkItem?
    /// Hält den Bildschirm wach, solange aufgenommen wird – sonst würde die Sperre eine lange Aufnahme beenden.
    private var awake: NSObjectProtocol?
    /// Aufnahme, die fertig wurde, während gerade das Modell gewechselt wurde.
    private var queuedAudio: (samples: [Float], send: Bool)?
    /// Während der Aufnahme kam Return: Der Text wird nach dem Einfügen abgeschickt.
    private var sendAfterwards = false
    /// Bei längeren Aufnahmen läuft das Mikrofon nach dem Loslassen kurz weiter: Wer die Taste nur aus Versehen
    /// losgelassen hat und gleich wieder drückt, diktiert einfach weiter.
    private var releaseGrace: DispatchWorkItem?
    /// Die dabei schon vorgezogene Umwandlung – so kostet die Schonfrist keine Wartezeit.
    private var graceEarly: (id: Int, text: String?, cancellation: Cancellation)?
    /// Vorgezogene Umwandlungen, deren Frist abgelaufen ist und deren Text noch kommt – er wird auf jeden Fall geliefert
    /// (true: und danach abgeschickt).
    private var awaitingEarly: [Int: Bool] = [:]
    private var earlyCount = 0
    /// Umwandlungen, deren Ergebnis noch aussteht – solange zeigt die Anzeige „arbeitet“ statt zu verschwinden.
    private var working = 0
    private var lastSecureNotice = Date.distantPast
    /// Die Nachbearbeitung fragt die Rechtschreibprüfung und gehört nicht auf den Hauptthread. Seriell, damit die
    /// Ergebnisse in ihrer Reihenfolge bleiben.
    private let cleanup = DispatchQueue(label: "steno.cleanup", qos: .userInitiated)

    private enum Timing {
        static let holdDelay = 0.15        // so lange warten, damit ⌥L (@) & Co. kein Diktat starten
        static let tap = 0.3               // kürzer ist ein Tippen, länger ein Halten
        static let shortcutWindow = 0.6    // nur so lange bricht eine weitere Taste das Halten ab
        static let resumeWindow = 3.0
        static let resumeSlack = 0.5       // die Aufnahme startet erst kurz nach dem Drücken
        static let releaseGrace = 0.6      // so lange darf man nach dem Loslassen wieder drücken …
        static let graceAfter = 3.0        // … sofern die Aufnahme schon so lange läuft
        static let doubleTap = 0.45
        static let mediaPauseDelay = 0.35  // erst pausieren, wenn es sicher kein Tippen ist
        static let maximum = 15.0 * 60     // Sicherheitsgrenze für eine einzelne Aufnahme
    }

    init() {
        microphone.onLevel = { [overlay] level in
            DispatchQueue.main.async { overlay.model.push(level: level) }
        }
        // Der Startton erst, wenn das Mikrofon wirklich zuhört.
        microphone.onListening = {
            #if DEBUG
            Latency.step("Mikrofon hört")
            #endif
            Sound.start.play()
        }
        microphone.onFailure = { [weak self] in self?.microphoneFailed($0) }
        #if DEBUG
        Latency.watchMainThread()
        #endif
    }

    /// Beim Start einmal anlegen, was das erste Diktat sonst aufhalten würde.
    func warmUp() {
        overlay.warmUp()
        // Die Rechtschreibprüfung muss auf dem Hauptthread entstehen – ihr erster Aufruf im Hintergrund kann hängen.
        _ = NSSpellChecker.shared
    }

    func handle(_ event: HotKeyMonitor.Event) {
        #if DEBUG
        Latency.received(event)
        #endif
        switch event {
        case .down(let time): keyDown(at: time)
        case .up(let time): keyUp(at: time)
        case .chord(let time): keyChord(at: time)
        case .escape: escape()
        case .pasteLast: pasteLast()
        case .send: send()
        case .note: break  // die Notiz gehört dem Meeting
        }
    }

    /// Bildschirm gesperrt, Ruhezustand, Benutzerwechsel: sofort aufhören zuzuhören.
    func abortForSystemEvent() {
        pendingStart?.cancel()
        cancelRecording()
        resumable = nil
    }

    /// Nach „Verlauf löschen“: auch den letzten Text aus dem Speicher nehmen.
    func forgetLast() {
        lastText = nil
        pendingResult = nil
        resumable = nil
    }

    func shutdown() {
        if mode != .idle { _ = stopRecording() }
        media.resumeNow()
        transcriber?.close()
        HistoryStore.shared.flush()
    }

    // MARK: Tasten

    private func keyDown(at time: TimeInterval) {
        chordInPress = false
        if mode == .holding, releaseGrace != nil {
            // Nur kurz losgelassen: weiter aufnehmen, als wäre nichts gewesen.
            releaseGrace?.cancel()
            releaseGrace = nil
            dropGraceEarly()
            return
        }
        pressedAt = time
        guard mode == .idle else { return }
        // Das Mikrofon öffnet schon, während noch offen ist, ob ein Diktat oder ein Kürzel wie ⌥L kommt.
        microphone.prepare()
        schedule(&pendingStart, after: Timing.holdDelay) { [weak self] in self?.startRecording(.holding) }
    }

    private func keyUp(at time: TimeInterval) {
        let held = time - pressedAt
        switch mode {
        case .handsFree:
            if held < 2 * Timing.tap, !chordInPress { finishRecording() }
        case .holding:
            if held < Timing.tap, !chordInPress {
                cancelRecording(keepOverlay: true)
                registerTap(at: time)
            } else if Date.now.timeIntervalSince(startedAt) >= Timing.graceAfter, transcriber != nil {
                beginReleaseGrace()
            } else {
                finishRecording()
            }
        case .idle:
            pendingStart?.cancel()
            if held < Timing.tap, !chordInPress { registerTap(at: time) }
        }
    }

    private func registerTap(at time: TimeInterval) {
        if let lastTap, time - lastTap < Timing.doubleTap {
            self.lastTap = nil
            startRecording(.handsFree)
            return
        }
        lastTap = time
        // Kommt kein zweites Tippen, die kurz aufgeblitzte Anzeige wieder einfahren.
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.doubleTap) { [weak self] in
            guard let self, self.mode == .idle, self.lastTap == time, self.overlay.isShowingRecording else { return }
            self.showPendingOrHide()
        }
    }

    /// ⌥ + andere Taste gleich zu Beginn ist ein Tastenkürzel (⌥L = @) und kein Diktat.
    /// Später, oder freihändig, darf man nebenbei tippen – z. B. ⌘⇥ zum App-Wechsel.
    private func keyChord(at time: TimeInterval) {
        chordInPress = true
        lastTap = nil
        pendingStart?.cancel()
        // Vom ersten Tippen eines Doppeltipps kann die Anzeige noch stehen.
        if mode == .idle, overlay.isShowingRecording { overlay.hide() }
        if mode == .holding, time - pressedAt < Timing.shortcutWindow { cancelRecording() }
    }

    /// Return: freihändig endet die Aufnahme damit wie mit einem Tippen, gehalten wie gewohnt beim Loslassen.
    private func send() {
        guard mode != .idle else { return }
        sendAfterwards = true
        if mode == .handsFree { finishRecording() } else { overlay.showSendHint() }
    }

    private func escape() {
        guard mode != .idle else { return }
        dropGraceEarly()
        let duration = Date.now.timeIntervalSince(startedAt)
        let samples = collectSamples()
        if let pendingResult {
            self.pendingResult = nil
            overlay.showResult(pendingResult, copied: true)
            if duration >= 1 { resumable = (samples, duration) }
            schedule(&resumeExpiry, after: Timing.resumeWindow + Timing.resumeSlack) { [weak self] in self?.resumable = nil }
            return
        }
        if duration >= 1 {
            resumable = (samples, duration)
            schedule(&resumeExpiry, after: Timing.resumeWindow + Timing.resumeSlack) { [weak self] in self?.resumable = nil }
            overlay.showMessage(L("Abgebrochen – innerhalb von 3 s %@ drücken, um fortzusetzen", hotKey.symbol), seconds: Timing.resumeWindow)
        } else {
            overlay.showMessage(L("Abgebrochen"), seconds: 1)
        }
    }

    // MARK: Aufnahme

    private func startRecording(_ newMode: Mode) {
        guard mode == .idle else { return }
        // In Passwortfeldern ist die sichere Eingabe an: nicht zuhören, nichts einfügen.
        guard !IsSecureEventInputEnabled() else {
            if Date.now.timeIntervalSince(lastSecureNotice) > 5 {
                lastSecureNotice = .now
                overlay.showMessage(L("Eine Passworteingabe ist aktiv – so lange wird nicht diktiert."), seconds: 2.5)
            }
            return
        }
        guard transcriber != nil else { return overlay.showMessage(notReadyReason, seconds: 3) }
        // `resumable` bleibt stehen, bis es abläuft: ein erstes Tippen beim Doppeltipp soll es nicht verbrauchen.
        resumed = resumable
        startedAt = .now - (resumed?.duration ?? 0)
        mode = newMode
        sendAfterwards = false
        // Erst die Anzeige, dann das Mikrofon: Wie lange das Gerät zum Starten braucht, schwankt.
        overlay.showRecording(handsFree: newMode == .handsFree, since: startedAt)
        microphone.startInBackground()
        #if DEBUG
        Latency.overlayShown()
        #endif
        schedule(&pendingMediaPause, after: Timing.mediaPauseDelay) { [weak self] in self?.media.pause() }
        schedule(&recordingLimit, after: Timing.maximum) { [weak self] in self?.finishRecording() }
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled],
                                                     reason: "Steno nimmt auf")
    }

    private func stopRecording() -> [Float] {
        [pendingStart, pendingMediaPause, recordingLimit, releaseGrace].forEach { $0?.cancel() }
        releaseGrace = nil
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        let samples = microphone.stop()
        media.resume()
        mode = .idle
        return samples
    }

    /// Die Aufnahme – nach einem Fortsetzen mit dem abgebrochenen Teil davor.
    private func collectSamples() -> [Float] {
        let new = stopRecording()
        defer { resumed = nil }
        return withResumed(new)
    }

    private func withResumed(_ new: [Float]) -> [Float] {
        guard let resumed else { return new }
        return resumed.samples + [Float](repeating: 0, count: 4_000) + new
    }

    // MARK: Schonfrist nach dem Loslassen

    /// Wandelt schon um, was bis hierher gesagt wurde, und hört noch kurz weiter zu.
    private func beginReleaseGrace() {
        earlyCount += 1
        let id = earlyCount
        let cancellation = Cancellation()
        graceEarly = (id, nil, cancellation)
        runTranscription(withResumed(microphone.snapshot()), cancellation: cancellation) { [weak self] text in
            guard let self else { return }
            if let send = self.awaitingEarly.removeValue(forKey: id) {  // Frist schon vorbei: jetzt liefern
                self.working = max(0, self.working - 1)
                self.deliver(text, send: send)
            } else if self.graceEarly?.id == id {  // Frist läuft noch: bereithalten
                self.graceEarly?.text = text
            }  // sonst verworfen: weiterdiktiert oder abgebrochen
        }
        schedule(&releaseGrace, after: Timing.releaseGrace) { [weak self] in self?.endReleaseGrace(id) }
    }

    /// Die Taste kam nicht zurück: Aufnahme beenden und den vorgezogenen Text liefern.
    private func endReleaseGrace(_ id: Int) {
        releaseGrace = nil
        guard mode == .holding, let early = graceEarly, early.id == id else { return }
        graceEarly = nil
        _ = collectSamples()  // was nach dem Loslassen noch kam, gehört nicht dazu
        resumable = nil
        resumeExpiry?.cancel()
        Sound.stop.play()
        if let text = early.text {
            deliver(text, send: sendAfterwards)
        } else {
            awaitingEarly[id] = sendAfterwards
            working += 1
            overlay.showWorking()
        }
    }

    /// Die vorgezogene Umwandlung der laufenden Frist wird nicht mehr gebraucht.
    private func dropGraceEarly() {
        graceEarly?.cancellation.cancel()
        graceEarly = nil
    }

    private func cancelRecording(keepOverlay: Bool = false) {
        pendingStart?.cancel()
        guard mode != .idle else { return }
        dropGraceEarly()
        _ = stopRecording()
        resumed = nil
        guard !keepOverlay else { return }
        showPendingOrHide()
    }

    /// Das Mikrofon ist im Hintergrund nicht angesprungen – oder Steno darf es nicht benutzen.
    private func microphoneFailed(_ error: Error) {
        guard mode != .idle else { return }
        cancelRecording(keepOverlay: true)
        if case Microphone.Failure.notAllowed = error {
            overlay.showMessage(L("Kein Mikrofonzugriff – Steno-Fenster öffnen"), seconds: 3)
        } else {
            overlay.showMessage(L("Mikrofon lässt sich nicht starten"))
        }
    }

    /// Ein zurückgehaltenes Ergebnis zeigen statt es liegen zu lassen; läuft noch eine Umwandlung, „arbeitet“ zeigen.
    private func showPendingOrHide() {
        if let pendingResult {
            self.pendingResult = nil
            overlay.showResult(pendingResult, copied: true)
        } else if working > 0 {
            overlay.showWorking()
        } else {
            overlay.hide()
        }
    }

    private func finishRecording() {
        guard mode != .idle else { return }
        dropGraceEarly()
        let duration = Date.now.timeIntervalSince(startedAt)
        let samples = collectSamples()
        resumable = nil
        resumeExpiry?.cancel()
        Sound.stop.play()
        guard duration >= Timing.tap, samples.count >= 4_000 else { return showPendingOrHide() }
        guard transcriber != nil else {
            // Das Modell wird gerade gewechselt – die Aufnahme wartet darauf.
            queuedAudio = (samples, sendAfterwards)
            return overlay.showWorking()
        }
        transcribe(samples, send: sendAfterwards)
    }

    private func transcribe(_ samples: [Float], send: Bool) {
        overlay.showWorking()
        working += 1
        runTranscription(samples) { [weak self] text in
            guard let self else { return }
            self.working = max(0, self.working - 1)
            self.deliver(text, send: send)
        }
    }

    /// Whisper und Wörterbuch; das Ergebnis kommt auf dem Hauptthread.
    private func runTranscription(_ samples: [Float], cancellation: Cancellation? = nil, then: @escaping (String) -> Void) {
        guard let transcriber else { return }
        let vocabulary = DictionaryStore.shared.vocabulary
        let language = SpeechLanguage.current
        transcriber.transcribe(samples, prompt: vocabulary.whisperPrompt, language: language.whisperCode,
                               cancellation: cancellation) { [cleanup] raw in
            cleanup.async {
                let text = TextCleanup.apply(raw, vocabulary, language: language.whisperCode, swiss: language == .swissGerman)
                DispatchQueue.main.async { then(text) }
            }
        }
    }

    // MARK: Ergebnis

    /// Wohin der Text geht, klären die Bedienungshilfen im Hintergrund; entschieden wird erst mit ihrer Antwort.
    /// `send`: nach dem Einfügen abschicken – nur, wenn wirklich eingefügt wurde.
    private func deliver(_ result: String, send: Bool) {
        TextInsertion.inspect(probe: Settings.autoInsert) { [weak self] target in
            self?.deliver(result, to: target, send: send)
        }
    }

    private func deliver(_ result: String, to target: TextInsertion.Target, send: Bool) {
        #if DEBUG
        Latency.mark("Ergebnis")
        #endif
        let recordingAgain = mode != .idle  // schon das nächste Diktat angefangen: Anzeige nicht anfassen
        // Ein zurückgehaltenes Ergebnis aus der Zeit davor gehört mit dazu.
        var text = result
        if !recordingAgain, let pending = pendingResult {
            pendingResult = nil
            text = [pending, result].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard !text.isEmpty else {
            if !recordingAgain { overlay.showMessage(L("Nichts verstanden"), seconds: 1.2) }
            return
        }
        lastText = text
        // Ein zurückgehaltenes Ergebnis steht schon im Verlauf – nur das neue dazu.
        if !result.isEmpty { HistoryStore.shared.add(result) }
        if target.canType {  // nur gefragt, wenn eingefügt werden soll
            if !recordingAgain { working > 0 ? overlay.showWorking() : overlay.hide() }
            // Abgeschickt wird nur, was gerade diktiert wurde – nicht ein zurückgehaltener Text allein.
            insert(text, at: target, send: send && !result.isEmpty)
        } else if recordingAgain {
            // Nicht verlieren: in die Zwischenablage und nach der laufenden Aufnahme zeigen.
            TextInsertion.copy(text)
            pendingResult = [pendingResult, text].compactMap { $0 }.joined(separator: "\n")
        } else if Settings.autoInsert {
            overlay.showResult(text)
        } else {
            TextInsertion.copy(text)
            overlay.showResult(text, copied: true)
        }
    }

    /// ⌃⌥V: das letzte Diktat noch einmal, z. B. wenn es im falschen Fenster gelandet ist.
    private func pasteLast() {
        guard let text = lastText ?? HistoryStore.shared.entries.first?.text else {
            return overlay.showMessage(L("Noch kein Diktat im Verlauf"), seconds: 1.5)
        }
        TextInsertion.inspect { [weak self] target in
            if target.canType { self?.insert(text, at: target) } else { self?.overlay.showResult(text) }
        }
    }

    /// Mit Leerzeichen davor, wenn direkt vor dem Cursor schon Text steht. Lässt sich das Zeichen
    /// nicht lesen (Terminal), zählt: gerade eben schon in dieselbe App diktiert.
    private func insert(_ text: String, at target: TextInsertion.Target, send: Bool = false) {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let needsSpace: Bool
        if let before = target.characterBefore {
            needsSpace = before.last.map { !$0.isWhitespace && !"([{„‚»/".contains($0) } ?? false
        } else if let last = lastInsertion {
            needsSpace = last.app == app && Date.now.timeIntervalSince(last.date) < 120
        } else {
            needsSpace = false
        }
        TextInsertion.paste(needsSpace ? " " + text : text, send: send)
        lastInsertion = (.now, app)
    }

    private func schedule(_ slot: inout DispatchWorkItem?, after seconds: Double, _ action: @escaping () -> Void) {
        slot?.cancel()
        let work = DispatchWorkItem(block: action)
        slot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Leise Systemtöne für Start und Ende einer Aufnahme (abschaltbar).
enum Sound {
    case start, stop

    /// `play()` hält auf, bis der Ton läuft: beim ersten Mal über 200 ms, danach 10–25 ms. Die Anzeige soll
    /// darauf nicht warten.
    private static let queue = DispatchQueue(label: "steno.sound", qos: .userInitiated)

    func play() {
        guard Settings.sounds else { return }
        let name = self == .start ? "Tink" : "Pop"
        Self.queue.async {
            guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
            sound.volume = 0.3
            sound.play()
        }
    }
}
