import AppKit

// Steno --test datei.wav …  → Whisper und Wörterbuch ohne Taste und Mikrofon prüfen.
if let index = CommandLine.arguments.firstIndex(of: "--test") {
    let chosen = Settings.model.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : Paths.models.appendingPathComponent($0) }
    let model = [chosen].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        ?? ModelCatalog.all.map(\.localURL).first { FileManager.default.fileExists(atPath: $0.path) }
    guard let model, let transcriber = Transcriber(model: model.path, voiceDetector: Paths.voiceDetector) else {
        print("Kein Modell gefunden – erst die App starten, damit sie eins herunterlädt.")
        exit(1)
    }
    let vocabulary = DictionaryStore.shared.vocabulary
    let language = SpeechLanguage.current
    for path in CommandLine.arguments[(index + 1)...] {
        guard let samples = try? Microphone.load(URL(fileURLWithPath: path)) else {
            print("\(path): nicht lesbar")
            continue
        }
        let start = Date.now
        let raw = transcriber.transcribeNow(samples, prompt: vocabulary.whisperPrompt, language: language.whisperCode)
        print(String(format: "%@ (%.1f s Audio, %.2f s)", path, Double(samples.count) / 16_000, Date.now.timeIntervalSince(start)))
        print("  Whisper: \(raw)\n  Fertig:  \(TextCleanup.apply(raw, vocabulary, language: language.whisperCode, swiss: language == .swissGerman))")
    }
    transcriber.close()
    exit(0)
}

#if DEBUG
if let status = DevTools.main(CommandLine.arguments) { exit(status) }
if let status = Latency.main(CommandLine.arguments) { exit(status) }
#endif

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
