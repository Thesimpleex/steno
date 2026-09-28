import AppKit

/// Das kleine Notizfeld für laufende Meetings (⌃⌥N): Return legt die Eingabe in die Zeitleiste – leer als Markierung,
/// mit „!“ am Anfang als Aufgabe –, Esc schließt, ohne etwas zu speichern.
///
/// Das Feld bekommt die Tastatur, ohne Steno nach vorn zu holen; auch Diktate landen dann darin. Beim Schließen bekommt
/// die App davor den Fokus zurück.
final class QuickNote: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private static let size = NSSize(width: 480, height: 74)

    private let meeting: MeetingSession
    private let overlay: NotchOverlay
    private let panel: NotePanel
    private let field = NSTextField()
    private var previousApp: NSRunningApplication?

    init(meeting: MeetingSession, overlay: NotchOverlay) {
        self.meeting = meeting
        self.overlay = overlay
        panel = NotePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = makeContent()
    }

    /// `anchor`: die angeklickte Anzeige an der Notch – das Feld erscheint direkt darunter (bei der Blase darüber).
    func show(at anchor: NSRect? = nil) {
        guard meeting.state == .running, !panel.isVisible else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        field.stringValue = ""
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(Self.origin(for: Self.size, in: area, anchor: anchor))
        }
        // Ohne `NSApp.activate()`: Das Feld nimmt als nicht aktivierendes Panel trotzdem die Tastatur an, und das
        // Hauptfenster von Steno schiebt sich nicht über Zoom oder Teams.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Unter der Anzeige, bei der Blase unten darüber; ohne Anzeige etwas unter dem oberen Rand, damit die Notch frei bleibt.
    static func origin(for size: NSSize, in area: NSRect, anchor: NSRect?) -> NSPoint {
        guard let anchor else { return NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 64) }
        let x = min(max(anchor.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
        let below = anchor.minY - size.height - 8
        return NSPoint(x: x, y: below >= area.minY ? below : anchor.maxY + 8)
    }

    // MARK: Schließen

    /// Wer selbst woandershin klickt, behält seinen Fokus.
    func windowDidResignKey(_ notification: Notification) {
        close(restoringFocus: false)
    }

    func close(restoringFocus: Bool = true) {
        guard panel.isVisible else { return }
        let previous = previousApp
        previousApp = nil
        panel.orderOut(nil)
        if restoringFocus { _ = previous?.activate(options: []) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            save(textView.string)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func save(_ text: String) {
        // Ein eingefügter Text kann Zeilenumbrüche mitbringen; eine Notiz bleibt eine Zeile.
        let note = text.components(separatedBy: .newlines).joined(separator: " ")
        meeting.addNote(note)
        close()
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        overlay.confirm(trimmed.isEmpty || trimmed == "!" ? L("Markierung gesetzt")
                        : trimmed.hasPrefix("!") ? L("Aufgabe gespeichert") : L("Notiz gespeichert"))
    }

    // MARK: Aussehen

    private func makeContent() -> NSView {
        field.placeholderString = L("Notiz zum Meeting …")
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.frame = NSRect(x: 18, y: 34, width: Self.size.width - 36, height: 24)

        let hint = NSTextField(labelWithString: L("Return speichert · leer: Markierung · ! am Anfang: Aufgabe · Esc schließt"))
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: 18, y: 14, width: Self.size.width - 36, height: 15)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.addSubview(field)
        background.addSubview(hint)
        return background
    }
}

/// Ein Fenster ohne Titelleiste, das trotzdem Tastatureingaben annimmt – auch solange eine andere App aktiv bleibt.
private final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }  // `becomesKeyOnlyIfNeeded` bleibt aus: das Feld will sofort tippen
}
