#if DEBUG
import Foundation
import os

/// Nur in Debug-Builds: wie schnell ein Diktat startet und ob der Hauptthread hängt. Mitlesen:
///
///     log stream --style compact --predicate 'subsystem == "io.github.thesimpleex.steno" && category == "latency"'
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
}
#endif
