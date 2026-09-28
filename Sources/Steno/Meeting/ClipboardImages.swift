import AppKit

/// Bilder aus der Zwischenablage für das laufende Meeting: Wer einen Bildschirmausschnitt aufnimmt (⌘⌃⇧4),
/// findet ihn mit Zeitstempel in der Zeitleiste, ohne dafür ein Fenster zu öffnen.
final class ClipboardImages {
    private let meeting: MeetingSession
    private let overlay: NotchOverlay
    private let pasteboard = NSPasteboard.general
    private var seen = 0
    private var timer: Timer?

    init(meeting: MeetingSession, overlay: NotchOverlay) {
        self.meeting = meeting
        self.overlay = overlay
    }

    /// Was beim Start schon in der Ablage liegt, gehört nicht zum Meeting.
    func start() {
        stop()
        seen = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.1
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let image = Self.newImage(in: pasteboard, seen: &seen, ownChangeCount: TextInsertion.ownChangeCount) else { return }
        // Erst bestätigen, wenn wirklich eine neue Datei entstand – nicht bei einem doppelten Bild oder einem Fehler.
        meeting.addImage(image) { [overlay] saved in
            if saved { overlay.confirm(L("Bild gespeichert")) }
        }
    }

    /// Was neben einem Bild in der Ablage liegt, verrät kopierte Dateien (Finder legt das Symbol dazu),
    /// Auswahlen aus Office oder dem Browser und Passwortmanager. Das ist kein Bildschirmausschnitt.
    private static let notScreenshot: [NSPasteboard.PasteboardType] = [
        .fileURL, .string, .rtf, .html,
        .init("org.nspasteboard.TransientType"), .init("org.nspasteboard.ConcealedType"),
    ]

    /// Das Bild, das seit `seen` von außen in die Ablage kam. Was Steno selbst hineinlegt – das Diktat beim Einfügen,
    /// danach der alte Inhalt –, hat höchstens den eigenen Zählerstand und ist nie ein neues Bild.
    /// Der Inhalt wird erst gelesen, wenn die Typen stimmen: Text und alles andere bleiben unberührt.
    static func newImage(in pasteboard: NSPasteboard, seen: inout Int, ownChangeCount: Int) -> NSImage? {
        let count = pasteboard.changeCount
        guard count != seen else { return nil }
        seen = count
        guard count > ownChangeCount,
              let types = pasteboard.types, !types.contains(where: notScreenshot.contains),
              let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type) else { return nil }
        return NSImage(data: data)
    }

    // MARK: Aufnehmen

    /// Drückt ⌘⌃⇧4 für den Nutzer: macOS nimmt den Ausschnitt selbst auf und legt ihn in die Ablage, von wo `poll()` ihn
    /// holt. So braucht Steno keine Freigabe für Bildschirmaufnahmen, nur die Bedienungshilfen, die es ohnehin hat.
    static func takeScreenshot() {
        let source = CGEventSource(stateID: .privateState)
        for (key, down, flags) in screenshotKeys {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: HotKeyMonitor.ownEventMarker)
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Wie von Hand gedrückt: Sondertasten zuerst, „4“ (feste Tastenposition, in jedem Layout gleich), dann alles los.
    static let screenshotKeys: [(key: CGKeyCode, down: Bool, flags: CGEventFlags)] = {
        let modifiers: [(CGKeyCode, CGEventFlags)] = [(0x37, .maskCommand), (0x3B, .maskControl), (0x38, .maskShift)]
        var flags: CGEventFlags = []
        var keys: [(key: CGKeyCode, down: Bool, flags: CGEventFlags)] = []
        for (key, flag) in modifiers {
            flags.insert(flag)
            keys.append((key, true, flags))
        }
        keys += [(0x15, true, flags), (0x15, false, flags)]
        for (key, flag) in modifiers.reversed() {
            flags.remove(flag)
            keys.append((key, false, flags))
        }
        return keys
    }()
}
