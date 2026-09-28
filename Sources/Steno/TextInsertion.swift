import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Text an der Cursorposition einfügen – über die Zwischenablage und ⌘V, danach bekommt
/// die Zwischenablage ihren alten Inhalt zurück.
enum TextInsertion {
    /// Terminals und Editoren melden ihr Eingabefeld nicht zuverlässig über die Bedienungshilfen.
    private static let typingApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.exafunction.windsurf", "com.apple.dt.Xcode",
    ]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let controlRoles: Set<String> = [
        "AXSlider", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXIncrementor", "AXScrollBar",
        "AXSplitter", "AXColorWell", "AXDisclosureTriangle", "AXMenuButton", "AXStepper",
    ]

    // MARK: Wohin geht der Text?

    struct Target {
        /// Steht der Cursor in einem Feld, in das man tippen kann?
        var canType = false
        /// Das Zeichen direkt vor dem Cursor: "" am Feldanfang, nil wenn nicht lesbar (z. B. im Terminal).
        var characterBefore: String?
    }

    /// Die Bedienungshilfen warten auf eine hängende App bis zu einer Sekunde – deshalb eine eigene Queue.
    private static let queue = DispatchQueue(label: "steno.insertion", qos: .userInitiated)

    /// Fragt im Hintergrund, wohin ein Text ginge. Die Antwort kommt auf dem Hauptthread, in der Reihenfolge der
    /// Fragen. Ohne `probe` wird nichts gefragt, die Reihenfolge gilt trotzdem.
    static func inspect(probe: Bool = true, then done: @escaping (Target) -> Void) {
        // Eine Passworteingabe hat die sichere Tastatureingabe an: dann nie einfügen.
        let app = probe && !IsSecureEventInputEnabled() ? NSWorkspace.shared.frontmostApplication : nil
        // Bedienungshilfen-Abfragen an sich selbst würden den Hauptthread blockieren – dort direkt nachsehen.
        let own = app == .current
        queue.async {
            let other = own ? nil : app.map(target(of:))
            DispatchQueue.main.async { done(own ? ownTarget : other ?? Target()) }
        }
    }

    private static func target(of app: NSRunningApplication) -> Target {
        let typing = app.bundleIdentifier.map { typingApps.contains($0) || $0.hasPrefix("com.jetbrains.") } ?? false
        switch focus(in: app) {
        case .field(let field):
            guard typing || accepts(field) else { return Target() }
            return Target(canType: true, characterBefore: characterBefore(in: field))
        case .nothing: return Target(canType: typing)
        // Die App gibt keine Auskunft (hängt kurz, oder macOS kennt ihren Prozess gerade nicht):
        // dann trotzdem einfügen – das Diktat soll dort landen, wo der Cursor steht.
        case .unknown: return Target(canType: true)
        }
    }

    private static func accepts(_ field: AXUIElement) -> Bool {
        // Nie in Passwortfelder schreiben.
        if attribute(field, kAXSubroleAttribute) as? String == "AXSecureTextField" { return false }
        let role = attribute(field, kAXRoleAttribute) as? String ?? ""
        if textRoles.contains(role) { return true }
        if controlRoles.contains(role) { return false }
        return isSettable(field, kAXSelectedTextRangeAttribute) || isSettable(field, kAXValueAttribute)
    }

    private static func characterBefore(in field: AXUIElement) -> String? {
        guard let value = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &selection) else { return nil }
        guard selection.location > 0 else { return "" }
        var previous = CFRange(location: selection.location - 1, length: 1)
        guard let range = AXValueCreate(.cfRange, &previous) else { return nil }
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
                                                                range, &result)
        return status == .success ? result as? String : nil
    }

    /// Ein Textfeld in Steno selbst. Nur auf dem Hauptthread.
    private static var ownTarget: Target {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable else { return Target() }
        let location = view.selectedRange().location
        guard location > 0, location <= view.string.utf16.count else { return Target(canType: true, characterBefore: "") }
        return Target(canType: true,
                      characterBefore: (view.string as NSString).substring(with: NSRange(location: location - 1, length: 1)))
    }

    /// Hängt eine App, sollen Abfragen an sie Steno nicht mitreißen.
    static func limitWaitingForOtherApps() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    /// Was die Bedienungshilfen über das aktive Element der App sagen.
    private enum Focus {
        case field(AXUIElement)
        case nothing  // Die App meldet kein aktives Element.
        case unknown  // Die App gibt keine Auskunft.
    }

    private static func focus(in app: NSRunningApplication) -> Focus {
        guard let pid = processID(of: app) else { return .unknown }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        // Chromium/Electron-Apps (Slack, Discord, Chrome …) legen ihre Felder erst damit offen.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused)
        if status == .noValue {
            usleep(60_000)  // Chromium braucht nach dem Einschalten einen Moment
            status = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        switch status {
        case .success:
            guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .nothing }
            return .field(focused as! AXUIElement)
        // Ohne Bedienungshilfen-Freigabe klappt auch ⌘V nicht: dann lieber anzeigen.
        case .apiDisabled: return .nothing
        // Führt macOS den Prozess gerade nicht richtig, ist auch „kein Feld aktiv“ nicht verlässlich.
        case .noValue: return app.processIdentifier > 0 ? .nothing : .unknown
        default: return .unknown
        }
    }

    /// Die Prozessnummer der App. Nach einem Hintergrund-Update von Safari meldet macOS für die noch
    /// laufende Instanz manchmal keine (−1) – dann über den Programmpfad suchen.
    private static func processID(of app: NSRunningApplication) -> pid_t? {
        if app.processIdentifier > 0 { return app.processIdentifier }
        guard let path = app.executableURL?.path else { return nil }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == path { return pid }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    // MARK: Zwischenablage

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private static var savedClipboard: Snapshot?
    private static var pendingRestore: DispatchWorkItem?
    private static var ownChange = -1
    private static var nextPaste = Date.distantPast
    /// Der höchste Änderungszähler der Zwischenablage, den Steno selbst erzeugt hat (Einfügen, Zurücklegen, Kopieren).
    /// Was darüber liegt, kam von außen – etwa ein Screenshot. Nur auf dem Hauptthread benutzen.
    private(set) static var ownChangeCount = 0

    static func paste(_ text: String) {
        // Kurz nach dem letzten Einfügen warten, bis die App den Text gelesen hat – sonst bekäme sie schon den neuen.
        let wait = nextPaste.timeIntervalSinceNow
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { paste(text) }
            return
        }
        let pasteboard = NSPasteboard.general
        // Liegt von eben noch unser eigener Text in der Ablage, gilt weiter der Stand von davor.
        // Hat der Nutzer inzwischen selbst etwas kopiert, wird das gesichert.
        if let pending = pendingRestore, pasteboard.changeCount == ownChange {
            pending.cancel()
        } else {
            pendingRestore?.cancel()
            savedClipboard = restorableContents(of: pasteboard)
        }

        // Nur auf diesem Mac: nicht per Universal Clipboard an iPhone oder iPad weiterreichen.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        // Konvention für Clipboard-Manager: nicht in deren Verlauf aufnehmen.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let change = pasteboard.changeCount
        ownChange = change
        ownChangeCount = change
        nextPaste = Date.now.addingTimeInterval(0.4)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { pressCommandV() }

        let restore = DispatchWorkItem {
            defer { savedClipboard = nil; pendingRestore = nil }
            guard pasteboard.changeCount == change else { return }
            pasteboard.clearContents()  // unser Diktat nicht in der Ablage liegen lassen; der alte Inhalt gilt wieder normal
            ownChangeCount = pasteboard.changeCount
            guard let saved = savedClipboard, !saved.isEmpty else { return }
            pasteboard.writeObjects(saved.map { entries in
                let item = NSPasteboardItem()
                entries.forEach { item.setData($0.1, forType: $0.0) }
                return item
            })
            ownChangeCount = pasteboard.changeCount
        }
        pendingRestore = restore
        // Großzügig warten: langsame Apps (Electron, Remote-Desktop) lesen die Ablage erst spät.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: restore)
    }

    /// Was nach dem Einfügen zurück in die Ablage darf. Passwörter (von Passwort-Managern als „concealed“
    /// markiert), flüchtige Inhalte, zugesagte Dateien und sehr große Inhalte werden nicht aufbewahrt.
    private static func restorableContents(of pasteboard: NSPasteboard) -> Snapshot? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let skip: Set = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                         "org.nspasteboard.AutoGeneratedType", "com.apple.pasteboard.promised-file-url"]
        guard types.isDisjoint(with: skip) else { return nil }
        var total = 0
        var snapshot: Snapshot = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > 20_000_000 { return nil }  // sehr große Inhalte nicht im Speicher halten
                entries.append((type, data))
            }
            snapshot.append(entries)
        }
        return snapshot
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ownChangeCount = NSPasteboard.general.changeCount
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .privateState)
        let command: CGKeyCode = 0x37, v = KeyLayout.v
        for (key, down) in [(command, true), (v, true), (v, false), (command, false)] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: HotKeyMonitor.ownEventMarker)
            if key == v || down { event.flags = .maskCommand }
            event.post(tap: .cghidEventTap)
        }
    }
}
