import AppKit
import AVFoundation
import Combine
import ServiceManagement

/// Zustand, den die Fenster anzeigen.
final class AppState: ObservableObject {
    @Published var modelStatus = L("Wird geladen …")
    @Published var modelReady = false
    /// „Whisper Large v3 Turbo“, sobald ein Modell läuft.
    @Published var modelName: String?
    @Published var accessibility = false
    @Published var microphone = false
    @Published var microphoneDenied = false
    @Published var autostart = false
    @Published var pauseMusic = Settings.pauseMusic { didSet { Settings.pauseMusic = pauseMusic } }
    @Published var language = SpeechLanguage.current { didSet { SpeechLanguage.current = language } }
    @Published var sounds = Settings.sounds { didSet { Settings.sounds = sounds } }
    @Published var autoInsert = Settings.autoInsert { didSet { Settings.autoInsert = autoInsert } }
    @Published var hotKey = Settings.hotKey {
        didSet {
            Settings.hotKey = hotKey
            onKeyChanged(hotKey)
        }
    }
    var onKeyChanged: (HotKey) -> Void = { _ in }
    @Published var overlayStyle = Settings.overlayStyle {
        didSet {
            Settings.overlayStyle = overlayStyle
            onOverlayChanged(overlayStyle)
        }
    }
    var onOverlayChanged: (OverlayStyle) -> Void = { _ in }
    var previewOverlay: () -> Void = {}

    var ready: Bool { modelReady && accessibility && microphone }

    var requestAccessibility: () -> Void = {}
    var requestMicrophone: () -> Void = {}
    var setAutostart: (Bool) -> Void = { _ in }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState()
    private let dictation = Dictation()
    private let keys = HotKeyMonitor()
    private let models = ModelStore()
    private let meeting = MeetingSession()
    private let library = MeetingLibrary()
    private lazy var window = MainWindow(state: state, models: models, meeting: meeting, library: library)
    private lazy var onboarding = Onboarding(state: state, models: models)
    private lazy var quickNote = QuickNote(meeting: meeting, overlay: dictation.overlay)
    private lazy var clipboardImages = ClipboardImages(meeting: meeting, overlay: dictation.overlay)
    private var statusItem: NSStatusItem!
    private var subscriptions: Set<AnyCancellable> = []
    private var permissionTimer: Timer?
    private var meetingClock: Timer?
    private var askedForAccessibility = false
    /// Ohne Fenster legt macOS Steno sonst schlafen (App Nap), und Taste und Anzeige reagieren verzögert.
    private let noNap = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                              reason: "Steno wartet auf die Diktier-Taste")

    /// Lädt Modelle nacheinander. Beim Beenden wird hier gewartet, damit ein halb geladenes Modell sauber schließt.
    private let loader = DispatchQueue(label: "steno.loader")
    private var loadedTranscriber: Transcriber?  // nur auf `loader`
    private var loadedURL: URL?                  // nur auf `loader`
    private var modelLoading = false
    private var loadID = 0  // bei schnellen Wechseln zählt nur der letzte Ladevorgang
    private var announcedReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(for: self)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Glyph.idle
        statusItem.button?.setAccessibilityLabel("Steno")
        let menu = NSMenu()
        menu.autoenablesItems = false  // „Letztes Diktat kopieren“ schaltet sich selbst
        menu.delegate = self
        statusItem.menu = menu

        TextInsertion.limitWaitingForOtherApps()
        KeyLayout.startTracking()
        keys.hotKey = state.hotKey
        state.onKeyChanged = { [keys, dictation] in
            keys.hotKey = $0
            dictation.hotKey = $0
        }
        dictation.hotKey = state.hotKey
        dictation.overlay.style = state.overlayStyle
        dictation.warmUp()
        state.onOverlayChanged = { [dictation] in
            dictation.overlay.style = $0
            dictation.overlay.preview()
        }
        state.previewOverlay = { [dictation] in dictation.overlay.preview() }
        keys.handler = { [dictation, quickNote] event in
            if case .note = event { quickNote.show() } else { dictation.handle(event) }
        }
        dictation.onRecordingChanged = { [weak self] recording in
            self?.keys.isRecording = recording
            self?.statusItem.button?.image = recording ? Glyph.recording : Glyph.idle
            self?.statusItem.button?.setAccessibilityLabel(recording ? L("Steno – Aufnahme läuft") : "Steno")
        }
        HistoryStore.shared.onCleared = { [dictation] in dictation.forgetLast() }
        observeSystemEvents()
        observeMeeting()

        state.requestAccessibility = { [weak self] in self?.requestAccessibility() }
        state.requestMicrophone = { [weak self] in self?.requestMicrophone() }
        state.setAutostart = { [weak self] in self?.setAutostart($0) }
        repointAutostart()
        state.autostart = SMAppService.mainApp.status == .enabled
        refreshPermissions()

        // Wer schon diktiert hat, braucht keinen Einrichtungs-Assistenten mehr.
        if !Onboarding.completed, FileManager.default.fileExists(atPath: Paths.history.path) { Onboarding.completed = true }

        models.load = { [weak self] url, done in self?.loadModel(at: url, done: done) }
        models.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateModelStatus() }
            .store(in: &subscriptions)
        // Beim allerersten Start lädt der Assistent das Modell erst, wenn man dort angekommen ist.
        if Onboarding.completed || models.hasAnyModel { models.prepare() }
        updateModelStatus()

        _ = DictionaryStore.shared  // liest woerterbuch.json – und meldet sie, falls sie beschädigt war
        if let backup = DataFiles.lastBackup {
            dictation.overlay.showMessage(L("Eine beschädigte Datei wurde gesichert: %@", backup), seconds: 6)
        }

        if !Onboarding.completed || CommandLine.arguments.contains("--setup") {
            onboarding.show()
        } else if !state.accessibility || !state.microphone {
            window.show(.start)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        meeting.shutdown()  // vor dem Diktat: Das schließt das Modell, das die letzten Abschnitte noch braucht
        dictation.shutdown()
        loader.sync { loadedTranscriber?.close() }
    }

    /// Erneutes Öffnen aus „Programme“ oder dem Dock zeigt das Fenster.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show(.start)
        return true
    }

    /// Sperren, Ruhezustand, Benutzerwechsel: laufende Aufnahme sofort beenden.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [dictation] _ in dictation.abortForSystemEvent() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main) { [dictation] _ in
            dictation.abortForSystemEvent()
        }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in HistoryStore.shared.expire() }.tolerance = 600
    }

    // MARK: Modell

    /// Tauscht das Modell. Das alte wird vorher freigegeben – zwei große Modelle gleichzeitig wären mehrere GB.
    /// Lässt sich das neue nicht laden, kommt das alte zurück.
    private func loadModel(at url: URL, done: @escaping (Bool) -> Void) {
        loadID += 1
        let id = loadID
        modelLoading = true
        dictation.transcriber = nil
        meeting.transcriber = nil
        updateModelStatus()
        loader.async {
            let previousURL = self.loadedURL
            self.loadedTranscriber?.close()  // wartet, falls gerade noch ein Diktat damit läuft
            self.loadedTranscriber = nil
            var transcriber = Transcriber(model: url.path, voiceDetector: Paths.voiceDetector)
            let loaded = transcriber != nil
            if !loaded, let previousURL { transcriber = Transcriber(model: previousURL.path, voiceDetector: Paths.voiceDetector) }
            self.loadedTranscriber = transcriber
            self.loadedURL = transcriber == nil ? nil : (loaded ? url : previousURL)
            DispatchQueue.main.async {
                done(loaded)
                guard id == self.loadID else { return }  // inzwischen wurde schon ein anderes Modell gewählt
                self.dictation.transcriber = transcriber
                self.meeting.transcriber = transcriber
                self.modelLoading = false
                if !loaded { self.dictation.overlay.showMessage(L("Diese Modelldatei lässt sich nicht laden."), seconds: 3) }
                self.updateModelStatus()
            }
        }
    }

    private func updateModelStatus() {
        let problem: String?
        if modelLoading {
            problem = L("Wird geladen …")
        } else if dictation.transcriber != nil {
            problem = nil
        } else {
            switch models.download {
            case .loading(let model, let received):
                problem = L("Wird heruntergeladen … %lld %%", Int(Double(received) / Double(model.bytes) * 100))
            case .checking: problem = L("Wird geprüft …")
            case .failed(_, let reason): problem = reason
            case .idle: problem = models.problem ?? L("Kein Sprachmodell – bitte in den Einstellungen wählen.")
            }
        }
        // „Kein Sprachmodell – …“ nennt das Modell schon selbst; sonst „Sprachmodell: …“ davor.
        dictation.notReadyReason = problem.map { $0.localizedCaseInsensitiveContains(L("Sprachmodell")) ? $0 : L("Sprachmodell: %@", $0) } ?? ""
        state.modelReady = problem == nil
        announceReadyIfComplete()
        if let problem {
            state.modelStatus = problem
            state.modelName = nil
        } else {
            let name = models.name(of: models.active ?? models.selection)
            state.modelName = "Whisper " + name
            state.modelStatus = models.problem.map { "\($0) – " + L("vorübergehend: %@", name) }
                ?? L("%@ – läuft komplett auf diesem Mac.", "Whisper " + name)
        }
    }

    // MARK: Freigaben

    /// Solange etwas fehlt, oft nachsehen; danach nur noch selten.
    private func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if state.accessibility != trusted { state.accessibility = trusted }
        if state.microphone != (status == .authorized) { state.microphone = status == .authorized }
        if state.microphoneDenied != (status == .denied) { state.microphoneDenied = status == .denied }
        if trusted {
            if keys.isRunning { keys.ensureEnabled() } else { _ = keys.start() }
        }
        announceReadyIfComplete()
        let interval: TimeInterval = trusted && status == .authorized ? 30 : 1.5
        if permissionTimer?.timeInterval != interval {
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.refreshPermissions()
            }
            permissionTimer?.tolerance = interval * 0.2
        }
    }

    /// Einmal kurz an der Notch melden, sobald wirklich alles bereit ist (Taste, Mikrofon, Modell).
    private func announceReadyIfComplete() {
        guard !announcedReady, keys.isRunning, state.microphone, state.modelReady else { return }
        announcedReady = true
        dictation.overlay.showMessage(L("Bereit – %@ halten oder zweimal tippen", state.hotKey.shortName), seconds: 3)
    }

    /// Erster Klick: macOS fragen. Nach einem Update ohne festes Zertifikat hängt aber oft noch ein alter,
    /// ungültiger Eintrag in der Liste – den räumt tccutil vorher weg. Weitere Klicks öffnen die Einstellungen.
    private func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        guard !askedForAccessibility else { return openSettings("Privacy_Accessibility") }
        askedForAccessibility = true
        let bundle = Bundle.main.bundleIdentifier ?? "io.github.thesimpleex.steno"
        DispatchQueue.global(qos: .userInitiated).async {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundle]
            try? reset.run()
            reset.waitUntilExit()
            DispatchQueue.main.async {
                let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(prompt)
            }
        }
    }

    private func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.refreshPermissions() }
            }
        } else {
            openSettings("Privacy_Microphone")
        }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private func setAutostart(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else {
            state.autostart = on
            return
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            dictation.overlay.showMessage(L("Beim Anmelden öffnen ließ sich nicht einschalten: %@", error.localizedDescription), seconds: 4)
        }
        state.autostart = SMAppService.mainApp.status == .enabled
        if state.autostart { UserDefaults.standard.set(Bundle.main.bundlePath, forKey: Self.autostartPathKey) }
    }

    private static let autostartPathKey = "autostartBundlePath"

    /// Der Anmeldeeintrag merkt sich die Kopie, von der aus er eingeschaltet wurde – auch eine aus dem
    /// Build-Ordner. SMAppService verrät diesen Pfad nicht, deshalb merken wir ihn selbst und tragen
    /// neu ein, sobald die installierte Kopie läuft. Nur aus einem Programme-Ordner, damit nie wieder
    /// eine Build-Kopie beim Anmelden startet. Einmal pro Pfad, weil macOS bei jedem Eintragen eine Mitteilung zeigt.
    private func repointAutostart() {
        let path = Bundle.main.bundlePath
        let folders = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        guard SMAppService.mainApp.status == .enabled,
              folders.contains(where: { path.hasPrefix($0) }),
              UserDefaults.standard.string(forKey: Self.autostartPathKey) != path else { return }
        // Schlägt es fehl, zeigt das Menü danach den echten Stand.
        try? SMAppService.mainApp.unregister()
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(path, forKey: Self.autostartPathKey)
        } catch {
            // Sonst wäre der Autostart still aus.
            dictation.overlay.showMessage(L("Beim Anmelden öffnen ließ sich nicht einschalten: %@", error.localizedDescription), seconds: 4)
        }
    }

    // MARK: Meeting

    /// Was ein laufendes Meeting nebenbei braucht: das Kürzel ⌃⌥N, Bilder aus der Zwischenablage, den Hinweis an der Notch
    /// und die Zeit neben dem Symbol in der Menüleiste.
    private func observeMeeting() {
        meeting.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.meetingChanged($0) }
            .store(in: &subscriptions)
        meeting.$levels
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [model = dictation.overlay.model] in model.meetingLevels = $0 }
            .store(in: &subscriptions)
        // Klick auf die Anzeige an der Notch: Notiz oder Bildschirmausschnitt, ohne das Steno-Fenster zu öffnen.
        dictation.overlay.onNote = { [weak self] in self?.quickNote.show(at: $0) }
        dictation.overlay.onScreenshot = { ClipboardImages.takeScreenshot() }
    }

    private func meetingChanged(_ state: MeetingSession.State) {
        let running = state == .running
        keys.isMeeting = running
        meetingClock?.invalidate()
        meetingClock = nil
        guard running else {
            clipboardImages.stop()
            quickNote.close()  // eine Notiz fände kein laufendes Meeting mehr
            dictation.overlay.endMeeting()
            statusItem.button?.title = ""
            statusItem.button?.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
            return
        }
        clipboardImages.start()
        dictation.overlay.showMeeting(since: meeting.info.startedAt, sources: meeting.info.sources)
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        showElapsedTime()
        meetingClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.showElapsedTime() }
        meetingClock?.tolerance = 0.2
    }

    private func showElapsedTime() {
        statusItem.button?.title = MeetingMarkdown.timestamp(Date.now.timeIntervalSince(meeting.info.startedAt))
    }

    // MARK: Menüleiste

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(label: state.ready ? L("Steno – bereit")
                     : state.modelReady ? L("Steno – Einrichtung offen") : "Steno – " + state.modelStatus)
        let key = state.hotKey.symbol
        menu.addItem(label: L("%@ halten · 2× %@ freihändig · Esc abbrechen · ⌃⌥V erneut einfügen", key, key))
        if !state.ready, state.modelReady {
            menu.addItem(action(L("⚠︎ Einrichtung abschließen …"), #selector(showStart)))
        }
        menu.addItem(.separator())
        menu.addItem(meetingItem)
        menu.addItem(.separator())
        menu.addItem(action(L("Steno öffnen …"), #selector(showStart)))
        menu.addItem(action(L("Verlauf …"), #selector(showHistory)))
        menu.addItem(action(L("Wörterbuch …"), #selector(showDictionary)))
        menu.addItem(action(L("Einstellungen …"), #selector(showSettings)))
        let copyLast = action(L("Letztes Diktat kopieren"), #selector(copyLast))
        copyLast.isEnabled = lastDictation != nil
        menu.addItem(copyLast)
        menu.addItem(.separator())

        let languages = NSMenu()
        for language in SpeechLanguage.allCases {
            let item = action("\(language.flag)  \(language.name)", #selector(chooseLanguage(_:)))
            item.representedObject = language.rawValue
            item.state = SpeechLanguage.current == language ? .on : .off
            languages.addItem(item)
        }
        let language = NSMenuItem(title: L("Diktiersprache"), action: nil, keyEquivalent: "")
        language.submenu = languages
        menu.addItem(language)

        let autostart = action(L("Beim Anmelden öffnen"), #selector(toggleAutostart))
        autostart.state = state.autostart ? .on : .off
        menu.addItem(autostart)
        menu.addItem(.separator())
        menu.addItem(action(L("Steno beenden"), #selector(quit)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Beenden, solange eins läuft; sonst öffnet „Starten“ die Meetings-Seite, dort steht das Formular.
    private var meetingItem: NSMenuItem {
        if meeting.state == .running { return action(L("Meeting beenden"), #selector(stopMeeting)) }
        let item = action(L("Meeting starten …"), #selector(startMeeting))
        item.isEnabled = meeting.state == .idle  // in der Zeit danach werden noch die letzten Abschnitte umgewandelt
        return item
    }

    @objc private func startMeeting() { window.show(.meetings) }
    @objc private func stopMeeting() { meeting.stop() }
    @objc func showStart() { window.show(.start) }
    @objc func showHistory() { window.show(.history) }
    @objc func showDictionary() { window.show(.dictionary) }
    @objc func showSettings() { window.show(.settings) }
    @objc func closeWindow() { window.close() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc private func toggleAutostart() { setAutostart(!state.autostart) }

    /// Wie ⌃⌥V: das letzte Diktat, nach einem Neustart das neueste aus dem Verlauf.
    private var lastDictation: String? { dictation.lastText ?? HistoryStore.shared.entries.first?.text }

    @objc private func copyLast() {
        if let text = lastDictation { TextInsertion.copy(text) }
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String, let language = SpeechLanguage(rawValue: code) {
            SpeechLanguage.current = language
            state.language = language
        }
    }
}

private extension NSMenu {
    func addItem(label: String) {
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    func addSubmenu(_ title: String, _ build: (NSMenu) -> Void) {
        let submenu = NSMenu(title: title)
        build(submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

/// ⌘Q schließt nur das Fenster – Steno bleibt in der Menüleiste. Ganz beenden: ⌥⌘Q.
/// Das Bearbeiten-Menü sorgt dafür, dass Kopieren und Einsetzen in den Textfeldern gehen.
enum MainMenu {
    static func make(for app: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addSubmenu("Steno") { m in
            m.addItem(withTitle: L("Über Steno"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: L("Einstellungen …"), action: #selector(AppDelegate.showSettings), keyEquivalent: ",").target = app
            m.addItem(.separator())
            m.addItem(withTitle: L("Steno ausblenden"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            m.addItem(withTitle: L("Fenster schließen (Steno läuft weiter)"), action: #selector(AppDelegate.closeWindow), keyEquivalent: "q")
                .target = app
            let quit = m.addItem(withTitle: L("Steno komplett beenden"), action: #selector(AppDelegate.quit), keyEquivalent: "q")
            quit.keyEquivalentModifierMask = [.command, .option]
            quit.target = app
        }
        menu.addSubmenu(L("Bearbeiten")) { m in
            m.addItem(withTitle: L("Widerrufen"), action: Selector(("undo:")), keyEquivalent: "z")
            m.addItem(withTitle: L("Wiederholen"), action: Selector(("redo:")), keyEquivalent: "Z")
            m.addItem(.separator())
            m.addItem(withTitle: L("Ausschneiden"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: L("Kopieren"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: L("Einsetzen"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: L("Alles auswählen"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        }
        menu.addSubmenu(L("Fenster")) { m in
            m.addItem(withTitle: L("Schließen"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            m.addItem(withTitle: L("Im Dock ablegen"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        }
        return menu
    }
}
