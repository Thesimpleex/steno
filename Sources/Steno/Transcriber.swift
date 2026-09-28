import Foundation
import os
import whisper

/// Ein Whisper-Modell über whisper.cpp mit Metal. whisper.cpp ist nicht threadsicher,
/// deshalb läuft jeder Aufruf auf derselben seriellen Queue.
final class Transcriber {
    private let queue = DispatchQueue(label: "steno.transcriber", qos: .userInitiated)
    /// Meeting-Abschnitte stehen hier an – so liegt immer höchstens einer vor einem Diktat auf `queue`.
    private let background = DispatchQueue(label: "steno.transcriber.background", qos: .utility)
    /// Diktate, die anstehen oder laufen. Solange es eins gibt, fängt kein Meeting-Abschnitt an.
    private let dictations = DispatchGroup()
    private var context: OpaquePointer?
    private let voiceDetector: String?
    private let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    private static let minimumSamples = 17_600      // whisper.cpp verlangt gut eine Sekunde Audio
    private static let windowSamples = 30 * 16_000  // so viel Audio liest Whisper auf einmal

    init?(model: String, voiceDetector: String?) {
        whisper_log_set({ _, _, _ in }, nil)
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(model, params) else { return nil }
        self.context = context
        self.voiceDetector = voiceDetector
        // Einmal Stille durchrechnen, damit die GPU-Kernel beim ersten Diktat schon kompiliert sind.
        queue.async { _ = self.run([], prompt: "", language: "de", detectSpeech: false) }
    }

    deinit { if let context { whisper_free(context) } }

    /// `cancellation`: wird sie ausgelöst, bevor die Umwandlung an der Reihe ist, entfällt sie („“ als Ergebnis).
    func transcribe(_ samples: [Float], prompt: String, language: String, cancellation: Cancellation? = nil,
                    completion: @escaping (String) -> Void) {
        dictations.enter()
        queue.async {
            defer { self.dictations.leave() }
            guard cancellation?.isCancelled != true else { return completion("") }
            completion(self.run(samples, prompt: prompt, language: language, detectSpeech: true))
        }
    }

    /// Für Meetings. Ein Diktat geht immer vor: Der Abschnitt fängt erst an, wenn keins mehr ansteht – und weil
    /// Abschnitte höchstens 20 s lang sind, wartet ein Diktat höchstens auf einen. Das Ergebnis kommt auf einer
    /// Hintergrund-Queue; nil heißt, das Modell wurde vorher geschlossen (Modellwechsel).
    func transcribeBackground(_ samples: [Float], prompt: String, language: String,
                              completion: @escaping (String?) -> Void) {
        background.async {
            self.dictations.wait()
            completion(self.queue.sync {
                self.context == nil ? nil : self.run(samples, prompt: prompt, language: language, detectSpeech: true)
            })
        }
    }

    func transcribeNow(_ samples: [Float], prompt: String, language: String) -> String {
        queue.sync { run(samples, prompt: prompt, language: language, detectSpeech: true) }
    }

    /// Vor dem Beenden aufrufen, sonst bricht ggml-metal beim Aufräumen mit einem Assert ab.
    func close() {
        queue.sync {
            if let context { whisper_free(context) }
            context = nil
        }
    }

    private func run(_ samples: [Float], prompt: String, language: String, detectSpeech: Bool) -> String {
        guard let context else { return "" }
        let audio = samples + [Float](repeating: 0, count: max(0, Self.minimumSamples - samples.count))
        let language = language == "auto" ? likelyLanguage(audio, context) : language
        let detector = detectSpeech ? voiceDetector : nil
        let promptTokens = tokenCount(prompt, context)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.no_context = true
        // Längere Aufnahmen liest Whisper in 30-Sekunden-Fenstern. Mit Zeitmarken setzt jedes Fenster am letzten
        // Satzende an statt mitten im Wort – sonst gingen dort Wörter verloren.
        params.no_timestamps = audio.count <= Self.windowSamples
        // Das Wörterbuch gilt in jedem Fenster, der Text des vorigen Fensters nicht: Verhört sich Whisper einmal,
        // soll sich das nicht als Schleife bis zum Ende fortsetzen.
        params.carry_initial_prompt = true
        params.n_max_text_ctx = promptTokens > 0 ? promptTokens + 1 : 0
        params.suppress_nst = true
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.vad = detector != nil

        let status = language.withCString { lang in
            prompt.withCString { promptText in
                (detector ?? "").withCString { detectorPath in
                    params.language = lang
                    params.initial_prompt = prompt.isEmpty ? nil : promptText
                    params.vad_model_path = detector == nil ? nil : detectorPath
                    return audio.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
                }
            }
        }
        guard status == 0 else { return "" }
        return (0..<whisper_full_n_segments(context))
            .compactMap { whisper_full_get_segment_text(context, $0).map { String(cString: $0) } }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func tokenCount(_ text: String, _ context: OpaquePointer) -> Int32 {
        guard !text.isEmpty else { return 0 }
        var tokens = [whisper_token](repeating: 0, count: 1024)
        return abs(whisper_tokenize(context, text, &tokens, Int32(tokens.count)))  // negativ: Puffer zu klein
    }

    /// Wahrscheinlichste Sprache unter den gängigen – freie Erkennung liegt bei kurzen Schnipseln gern daneben.
    /// Kostet einen zusätzlichen Encoder-Durchlauf.
    private func likelyLanguage(_ audio: [Float], _ context: OpaquePointer) -> String {
        let window = Array(audio.prefix(Self.windowSamples))  // die Erkennung schaut ohnehin nur auf die ersten 30 s
        let converted = window.withUnsafeBufferPointer { whisper_pcm_to_mel(context, $0.baseAddress, Int32($0.count), threads) }
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard converted == 0, whisper_lang_auto_detect(context, 0, threads, &probabilities) >= 0 else { return "de" }
        return SpeechLanguage.detectable.max { probabilities[Int(whisper_lang_id($0))] < probabilities[Int(whisper_lang_id($1))] } ?? "de"
    }
}

/// Lässt eine noch nicht begonnene Umwandlung ausfallen – etwa eine vorgezogene, die nicht mehr gebraucht wird.
final class Cancellation: @unchecked Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}
