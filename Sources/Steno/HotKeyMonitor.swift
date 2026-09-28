import AppKit
import Carbon
import os

/// Beobachtet systemweit die Diktier-Taste (Standard: linke ⌥). Braucht die Bedienungshilfen-Freigabe.
///
/// Der Event-Tap läuft auf einem eigenen Thread: Jede Taste im System wartet auf ihn,
/// er darf also nie hinter einem beschäftigten Hauptthread hängen.
final class HotKeyMonitor {
    /// Zeitstempel = Systemlaufzeit beim Tastendruck, nicht beim Verarbeiten auf dem Hauptthread.
    enum Event {
        case down(TimeInterval), up(TimeInterval)
        /// Während die Taste gehalten wird, kam eine andere dazu (z. B. ⌥L für @). `.up` folgt trotzdem.
        case chord(TimeInterval)
        case escape
        /// ⌃⌥V
        case pasteLast
        /// ⌃⌥N, nur während eines Meetings: Notiz, Markierung oder Aufgabe.
        case note
        /// Return während einer Aufnahme: einfügen und danach absenden.
        case send
    }

    /// Markiert Tastendrücke, die Steno selbst erzeugt (⌘V beim Einfügen) – die ignoriert der Tap.
    static let ownEventMarker: Int64 = 0x4449_4B54

    var handler: ((Event) -> Void)?
    private(set) var isRunning = false

    /// Während einer Aufnahme werden Esc und Return verschluckt: Esc soll nicht nebenbei einen Dialog schließen,
    /// Return schickt das Diktat ab.
    var isRecording: Bool {
        get { recording.withLock { $0 } }
        set { recording.withLock { $0 = newValue } }
    }

    /// Nur solange ein Meeting läuft, gehört ⌃⌥N Steno – sonst bleibt das Kürzel für andere Apps frei.
    var isMeeting: Bool {
        get { meeting.withLock { $0 } }
        set { meeting.withLock { $0 = newValue } }
    }

    /// Lässt sich jederzeit ändern; eine gerade gehaltene Taste wird trotzdem sauber losgelassen.
    var hotKey: HotKey {
        get { key.withLock { $0 } }
        set { key.withLock { $0 = newValue } }
    }

    private let recording = OSAllocatedUnfairLock(initialState: false)
    private let meeting = OSAllocatedUnfairLock(initialState: false)
    private let key = OSAllocatedUnfairLock(initialState: HotKey.leftOption)
    /// Tastatur-Abgriff (darf Ereignisse verschlucken), Maus-Abgriff (hört nur mit) und der Runloop ihres Threads.
    private let taps = OSAllocatedUnfairLock(uncheckedState: (keys: CFMachPort?.none, mouse: CFMachPort?.none, loop: CFRunLoop?.none))
    // Nur auf dem Tap-Thread benutzt:
    private var holding = false
    private var heldKey = HotKey.leftOption  // zählt fürs Loslassen, auch wenn die Einstellung inzwischen wechselt
    private var chorded = false
    private var shortcut = false  // kam zu einer schon gehaltenen anderen Sondertaste dazu – gar nicht beachten
    private static let escape: Int64 = 53
    private static let returnKeys: Set<Int64> = [36, 76]  // Return und Enter auf dem Ziffernblock

    func start() -> Bool {
        guard !isRunning else { return true }
        let callback: CGEventTapCallBack = { _, type, event, context in
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(context!).takeUnretainedValue()
            return monitor.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        func mask(_ types: [CGEventType]) -> CGEventMask { types.reduce(0) { $0 | CGEventMask(1) << $1.rawValue } }
        guard let keys = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask([.flagsChanged, .keyDown]), callback: callback,
                                           userInfo: context) else { return false }
        // Mausklicks zählen wie eine weitere Taste (⌘-Klick ist ein Kürzel, kein Diktat). Dieser Abgriff hört nur mit
        // und kann Klicks weder verzögern noch verschlucken.
        let mouse = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                      eventsOfInterest: mask([.leftMouseDown, .rightMouseDown, .otherMouseDown]),
                                      callback: callback, userInfo: context)
        taps.withLock { $0.keys = keys; $0.mouse = mouse }
        let thread = Thread { [taps] in
            let loop = CFRunLoopGetCurrent()
            taps.withLock { $0.loop = loop }
            for port in [keys, mouse].compactMap({ $0 }) {
                CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
            }
            CFRunLoopRun()
        }
        thread.name = "Steno-Tastatur"
        thread.qualityOfService = .userInteractive
        thread.start()
        isRunning = true
        return true
    }

    /// Wer die Bedienungshilfen aus- und wieder einschaltet, legt den Abgriff still. Dann neu anlegen –
    /// ein bloßes Wiedereinschalten reicht nicht immer.
    func ensureEnabled() {
        let current = taps.withLock { $0.keys }
        if let current, CFMachPortIsValid(current), CGEvent.tapIsEnabled(tap: current) { return }
        let old = taps.withLock { state -> (CFMachPort?, CFMachPort?, CFRunLoop?) in
            defer { state = (nil, nil, nil) }
            return (state.keys, state.mouse, state.loop)
        }
        [old.0, old.1].compactMap { $0 }.forEach { CFMachPortInvalidate($0) }
        if let loop = old.2 { CFRunLoopStop(loop) }
        isRunning = false
        _ = start()
    }

    /// true = Ereignis verschlucken.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMarker { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS hat den Tap kurz abgeschaltet; ob die Taste noch gedrückt ist, wissen wir nicht mehr.
            // Nur mit Freigabe wieder einschalten – sonst hielte ein toter Abgriff die Eingaben auf.
            if AXIsProcessTrusted(), let keys = taps.withLock({ $0.keys }) { CGEvent.tapEnable(tap: keys, enable: true) }
            if holding, !shortcut { send(.up(now)) }
            holding = false

        case .flagsChanged where holding && keyCode == heldKey.keyCode:
            if event.flags.rawValue & heldKey.flag == 0 {
                holding = false
                if !shortcut { send(.up(now)) }
            }

        case .flagsChanged where !holding && keyCode == hotKey.keyCode:
            let key = hotKey
            let flags = event.flags.rawValue
            guard flags & key.flag != 0 else { break }
            holding = true
            heldKey = key
            chorded = false
            // Hielt man schon eine andere Sondertaste oder eine Maustaste (Ziehen im Finder), ist das ein Kürzel.
            let fn = key == .function ? 0 : flags & CGEventFlags.maskSecondaryFn.rawValue
            let mouseDown = [CGMouseButton.left, .right, .center].contains {
                CGEventSource.buttonState(.combinedSessionState, button: $0)
            }
            shortcut = flags & HotKey.modifierFlags & ~key.flag != 0 || fn != 0 || mouseDown
            if !shortcut { send(.down(now)) }

        case .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            markChord(now)

        case .keyDown:
            let flags = event.flags
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let controlOption = flags.contains([.maskControl, .maskAlternate]) && flags.isDisjoint(with: [.maskCommand, .maskShift])
            if keyCode == Int64(KeyLayout.v), controlOption {
                markChord(now)
                if !repeating { send(.pasteLast) }
                return true
            }
            if keyCode == Int64(KeyLayout.n), controlOption, isMeeting {
                markChord(now)
                if !repeating { send(.note) }
                return true
            }
            // Return gehört während der Aufnahme dem Diktat, nicht der App darunter – und zählt nicht als Tastenkürzel.
            if Self.returnKeys.contains(keyCode), isRecording, Self.isPlainReturn(flags, holding: holding ? heldKey : nil) {
                if !repeating { send(.send) }
                return true
            }
            markChord(now)
            if keyCode == Self.escape {
                send(.escape)
                return isRecording
            }

        default:
            break
        }
        return false
    }

    /// Nur ein schlichtes Return schickt ab. ⇧↩ (neue Zeile in Slack & Co.), ⌘↩ und ⌃↩ gehören der App.
    /// Die gehaltene Diktier-Taste setzt ihr Sammel-Bit selbst – sie zählt nicht mit.
    static func isPlainReturn(_ flags: CGEventFlags, holding key: HotKey?) -> Bool {
        let families: [(CGEventFlags, UInt64)] = [(.maskShift, 0x02 | 0x04), (.maskCommand, 0x08 | 0x10),
                                                  (.maskControl, 0x01 | 0x2000)]
        return families.allSatisfy { generic, sides in
            guard flags.contains(generic) else { return true }
            guard let key, sides & key.flag != 0 else { return false }
            return flags.rawValue & sides & ~key.flag == 0  // nur die andere Seite derselben Taste zählt
        }
    }

    #if DEBUG
    /// Für die Tests: ein Ereignis so verarbeiten, als käme es vom Tap.
    func feed(_ type: CGEventType, _ event: CGEvent) -> Bool { handle(type, event) }
    #endif

    private func markChord(_ time: TimeInterval) {
        guard holding, !shortcut, !chorded else { return }
        chorded = true
        send(.chord(time))
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { self.handler?(event) }
    }
}

/// Welche Tasten im aktuellen Tastaturlayout „v“ und „n“ sind (auf Dvorak z. B. nicht die üblichen).
enum KeyLayout {
    private static let cached = OSAllocatedUnfairLock(initialState: (v: CGKeyCode(9), n: CGKeyCode(45)))
    static var v: CGKeyCode { cached.withLock { $0.v } }
    static var n: CGKeyCode { cached.withLock { $0.n } }

    /// Auf dem Hauptthread aufrufen – die Eingabequellen-API verlangt das.
    static func startTracking() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in refresh() }
    }

    private static func refresh() {
        let codes = (v: lookUp("v", qwerty: 9) ?? 9, n: lookUp("n", qwerty: 45) ?? 45)
        cached.withLock { $0 = codes }
    }

    private static func lookUp(_ character: Character, qwerty: CGKeyCode) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        // Layouts wie „Dvorak – QWERTY ⌘“ schalten bei gedrückter ⌘-Taste auf QWERTY um.
        if let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName),
           (Unmanaged<CFString>.fromOpaque(name).takeUnretainedValue() as String).hasSuffix("⌘") { return qwerty }
        guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        let target = character.utf16.first
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<CGKeyCode(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == target { return code }
            }
            return nil
        }
    }
}
