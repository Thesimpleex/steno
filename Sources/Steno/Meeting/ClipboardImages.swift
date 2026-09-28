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
        meeting.addImage(image)
        overlay.confirm(L("Bild gespeichert"))
    }

    /// Das Bild, das seit `seen` von außen in die Ablage kam. Was Steno selbst hineinlegt – das Diktat beim Einfügen,
    /// danach der alte Inhalt –, hat höchstens den eigenen Zählerstand und ist nie ein neues Bild.
    /// Der Inhalt wird erst gelesen, wenn der Typ stimmt: Text und alles andere bleiben unberührt.
    static func newImage(in pasteboard: NSPasteboard, seen: inout Int, ownChangeCount: Int) -> NSImage? {
        let count = pasteboard.changeCount
        guard count != seen else { return nil }
        seen = count
        guard count > ownChangeCount,
              let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type) else { return nil }
        return NSImage(data: data)
    }
}
