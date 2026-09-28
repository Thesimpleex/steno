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
        /// Die App, die beim Nachsehen die Tastatur hatte – auch Steno selbst.
        var app: NSRunningApplication?

        /// Hat sie die Tastatur noch? `ownField`: Ein Textfeld in Steno hat sie gerade – das Notizfeld auch dann, wenn
        /// Steno nicht vorn ist.
        func isCurrent(frontmost: NSRunningApplication?, ownField: Bool) -> Bool {
            guard let app else { return false }
            return app == .current ? ownField : !ownField && frontmost == app
        }

        /// Ist das die App, in der Return gedrückt wurde? Nur dorthin darf das Return nachher gehen.
        func belongs(to receiver: Receiver) -> Bool {
            guard let app else { return false }
            return Receiver(app) == receiver
        }
    }

    /// Die App, die beim Druck auf Return die Tastatur hatte.
    struct Receiver: Equatable {
        var pid: pid_t
        var bundleID: String?

        init(_ app: NSRunningApplication?) {
            pid = app?.processIdentifier ?? 0
            bundleID = app?.bundleIdentifier
        }
    }

    /// Wer jetzt die Tastatur hat – ein eigenes Feld zählt als Steno. Nur auf dem Hauptthread.
    static var keyboardReceiver: Receiver {
        Receiver(ownField != nil ? .current : NSWorkspace.shared.frontmostApplication)
    }

    /// Die Bedienungshilfen warten auf eine hängende App bis zu einer Sekunde – deshalb eine eigene Queue.
    private static let queue = DispatchQueue(label: "steno.insertion", qos: .userInitiated)

    /// Fragt im Hintergrund, wohin ein Text ginge. Die Antwort kommt auf dem Hauptthread, in der Reihenfolge der
    /// Fragen. Ohne `probe` wird nichts gefragt, die Reihenfolge gilt trotzdem.
    static func inspect(probe: Bool = true, then done: @escaping (Target) -> Void) {
        var app: NSRunningApplication?
        // Bei sicherer Tastatureingabe (Passwortfeld, Terminal) nie einfügen.
        if probe, !IsSecureEventInputEnabled() {
            // Ein eigenes Feld zuerst: Das Notizfeld hat die Tastatur, auch wenn macOS Steno dafür nicht nach vorn lässt.
            app = ownField != nil ? .current : NSWorkspace.shared.frontmostApplication
        }
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
            return Target(canType: true, characterBefore: characterBefore(in: field), app: app)
        case .nothing: return Target(canType: typing, app: app)
        // Die App gibt keine Auskunft (hängt kurz, oder macOS kennt ihren Prozess gerade nicht):
        // dann trotzdem einfügen – das Diktat soll dort landen, wo der Cursor steht.
        case .unknown: return Target(canType: true, app: app)
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

    /// Das Textfeld in Steno, das gerade die Tastatur hat. Nur auf dem Hauptthread.
    private static var ownField: NSTextView? {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable else { return nil }
        return view
    }

    /// Ein Textfeld in Steno selbst. Nur auf dem Hauptthread.
    private static var ownTarget: Target {
        guard let view = ownField else { return Target() }
        let text = view.string as NSString
        let location = view.selectedRange().location
        let before = location > 0 && location <= text.length ? text.substring(with: NSRange(location: location - 1, length: 1)) : ""
        return Target(canType: true, characterBefore: before, app: .current)
    }

    /// Hat noch die App die Tastatur, in der nachgesehen wurde – und kam keine sichere Tastatureingabe dazwischen?
    /// Nur auf dem Hauptthread.
    private static func hasKeyboard(_ target: Target) -> Bool {
        !IsSecureEventInputEnabled() && target.isCurrent(frontmost: NSWorkspace.shared.frontmostApplication, ownField: ownField != nil)
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

    /// `send`: danach Return drücken, etwa um eine Chatnachricht abzuschicken. Text und Return gehen nur an die App, die
    /// beim Nachsehen die Tastatur hatte – hat sie inzwischen eine andere, kommt stattdessen `missed`.
    /// `pasted` kommt nur, wenn wirklich eingefügt wurde; `sent`: Return ging auch hinterher.
    static func paste(_ text: String, into target: Target, send: Bool = false, missed: @escaping () -> Void,
                      pasted: @escaping (_ sent: Bool) -> Void = { _ in }) {
        // Kurz nach dem letzten Einfügen warten, bis die App den Text gelesen hat – sonst bekäme sie schon den neuen.
        let wait = nextPaste.timeIntervalSinceNow
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { paste(text, into: target, send: send, missed: missed, pasted: pasted) }
            return
        }
        guard hasKeyboard(target) else { return missed() }
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard hasKeyboard(target) else { return missed() }
            pressCommandV()
            guard send else { return pasted(false) }
            // Erst abschicken, wenn die App den Text eingesetzt hat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let sent = hasKeyboard(target)
                if sent { pressReturn() }
                pasted(sent)
            }
        }

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

    /// Ein verschlucktes Return, das doch nichts abschickt, bekommt die App zurück – aber nur die, in der es gedrückt
    /// wurde, und nie bei sicherer Tastatureingabe. Nur auf dem Hauptthread.
    static func pressReturn(in receiver: Receiver) {
        guard !IsSecureEventInputEnabled(), keyboardReceiver == receiver else { return }
        pressReturn()
    }

    /// Wie ⌘V markiert, damit der eigene Tastatur-Abgriff es durchlässt.
    private static func pressReturn() {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: HotKeyMonitor.ownEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
