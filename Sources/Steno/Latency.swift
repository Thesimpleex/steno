#if DEBUG
import AVFoundation
import os

/// Nur in Debug-Builds: wie schnell ein Diktat startet und ob der Hauptthread hängt. Mitlesen:
///
///     log stream --style compact --predicate 'subsystem == "io.github.thesimpleex.steno" && category == "latency"'
///
/// Dazu zwei Prüfungen, die Freigaben brauchen und deshalb nur auf ausdrücklichen Aufruf laufen:
///
///     Steno --check-microphone   Mikrofon kalt und vorbereitet starten, Zeit bis zum ersten Puffer
///     Steno --check-send         nach 3 s „Steno“ ins aktive Textfeld einfügen und mit Return abschicken
enum Latency {
    private static let log = Logger(subsystem: "io.github.thesimpleex.steno", category: "latency")
    // Nur auf dem Hauptthread:
    private static var pressedAt: TimeInterval?
    private static var passStart = ProcessInfo.processInfo.systemUptime
    private static var marks: [String] = []
    private static var overlayPending = false

    /// Ein Tastenereignis ist auf dem Hauptthread angekommen.
    static func received(_ event: HotKeyMonitor.Event) {
        mark(String(String(describing: event).prefix { $0 != "(" }))
        guard case .down(let time) = event else { return }
        pressedAt = time
        log.notice("Taste → Hauptthread: \(milliseconds(since: time)) ms")
    }

    /// Die Anzeige wurde eingeblendet; gezeichnet ist sie am Ende dieses Durchlaufs.
    static func overlayShown() {
        step("Anzeige eingeblendet")
        overlayPending = true
    }

    /// Zeit seit dem Tastendruck.
    static func step(_ name: String) {
        mark(name)
        guard let pressedAt else { return }
        log.notice("Taste → \(name, privacy: .public): \(milliseconds(since: pressedAt)) ms")
    }

    /// Darf von jedem Thread kommen.
    static func duration(_ name: String, since start: TimeInterval) {
        log.notice("\(name, privacy: .public): \(milliseconds(since: start)) ms")
    }

    /// Was gerade auf dem Hauptthread läuft – wird genannt, falls dieser Durchlauf zu lange dauert.
    static func mark(_ name: String) {
        marks.append(name)
    }

    /// Meldet jeden Durchlauf des Hauptthreads über 50 ms. Gemessen wird vom Aufwachen bis nach dem Zeichnen.
    static func watchMainThread() {
        passStart = ProcessInfo.processInfo.systemUptime
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { _, activity in
            let now = ProcessInfo.processInfo.systemUptime
            guard activity == .beforeWaiting else {
                passStart = now
                marks.removeAll()
                return
            }
            if overlayPending, let pressedAt {
                overlayPending = false
                log.notice("Taste → Anzeige gezeichnet: \(milliseconds(since: pressedAt)) ms")
            }
            let busy = milliseconds(since: passStart)
            if busy > 50 {
                let what = marks.isEmpty ? "nichts markiert" : marks.joined(separator: ", ")
                log.notice("Hauptthread \(busy) ms belegt – \(what, privacy: .public)")
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func milliseconds(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    // MARK: Prüfungen

    static func main(_ arguments: [String]) -> Int32? {
        if arguments.contains("--check-microphone") { return checkMicrophone() }
        if arguments.contains("--check-send") { return checkSend() }
        return nil
    }

    private static func checkMicrophone() -> Int32 {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            var answered = false
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { answered = true } }
            while !answered { RunLoop.main.run(until: .now + 0.05) }
        }
        guard Microphone.authorized else {
            print("Kein Mikrofonzugriff – in den Systemeinstellungen für das Terminal erlauben.")
            return 1
        }
        let microphone = Microphone()
        var heardAt: TimeInterval?
        var failed = false
        microphone.onListening = { heardAt = ProcessInfo.processInfo.systemUptime }
        microphone.onFailure = { _ in failed = true }
        for prepared in [false, true, false, true] {
            if prepared {
                microphone.prepare()
                RunLoop.main.run(until: .now + 0.5)
            }
            heardAt = nil
            let start = ProcessInfo.processInfo.systemUptime
            microphone.startInBackground()
            while heardAt == nil, !failed, ProcessInfo.processInfo.systemUptime - start < 3 {
                RunLoop.main.run(until: .now + 0.005)
            }
            RunLoop.main.run(until: .now + 1)
            let seconds = Double(microphone.stop().count) / Microphone.format.sampleRate
            guard let heardAt, !failed else {
                print("Mikrofon lässt sich nicht starten")
                return 1
            }
            print(String(format: "%@: erster Puffer nach %.0f ms, %.1f s aufgenommen",
                         prepared ? "vorbereitet" : "kalt", (heardAt - start) * 1000, seconds))
            RunLoop.main.run(until: .now + 0.5)
        }
        return 0
    }

    private static func checkSend() -> Int32 {
        print("In 3 s wird „Steno“ ins aktive Textfeld eingefügt und mit Return abgeschickt …")
        RunLoop.main.run(until: .now + 3)
        TextInsertion.paste("Steno", send: true)
        RunLoop.main.run(until: .now + 2)
        return 0
    }
}
#endif
