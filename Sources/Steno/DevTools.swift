#if DEBUG
import AppKit
import SwiftUI

/// Werkzeuge für die Entwicklung, nur in Debug-Builds:
///
///     Steno --snapshots <ordner> [--lang en|de|fr]   alle Seiten als PNG, hell und dunkel
///     Steno --marketing <ordner> [--lang en|de|fr]   Bilder für README und Webseite
///
/// Die Bilder entstehen ohne Bildschirmaufnahme und mit Beispieldaten in einem eigenen Ordner.
enum DevTools {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func main(_ arguments: [String]) -> Int32? {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let folder = value(after: "--snapshots") ?? value(after: "--marketing") else { return nil }
        let language = value(after: "--lang")
        prepare(language: language)
        if arguments.contains("--marketing") { marketing(into: folder) } else { snapshots(into: folder) }
        return 0
    }

    // MARK: Vorbereitung

    /// Beispieldaten in einem eigenen Ordner; muss vor dem ersten Zugriff auf `Paths` laufen.
    private static func prepare(language: String?) {
        if let language, let bundle = Bundle(path: root.appendingPathComponent("Resources/\(language).lproj").path) {
            Localization.bundle = bundle
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("steno-devtools-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("STENO_DATA", folder.path, 1)

        sampleLanguage = language ?? "de"
        let texts = [
            pick("Kannst du mir bis Freitag die überarbeitete Präsentation schicken? Dann schaue ich sie mir am Wochenende an.",
                 "Can you send me the revised deck by Friday? I'll go through it over the weekend.",
                 "Pouvez-vous m’envoyer la présentation révisée d’ici vendredi ? Je la relirai ce week-end."),
            pick("Bitte fasse den Artikel in drei Stichpunkten zusammen und nenne die wichtigste Zahl.",
                 "Summarize the article in three bullet points and name the most important number.",
                 "Résume l’article en trois points et indique le chiffre le plus important."),
            pick("Termin mit Frau Meyer auf Donnerstag, 14 Uhr verschieben.",
                 "Move the meeting with Ms. Meyer to Thursday at 2 pm.",
                 "Déplacer le rendez-vous avec Mme Meyer à jeudi, 14 h."),
            pick("Die Einstellungsseite so umbauen, dass jede Zeile denselben Abstand hat.",
                 "Refactor the settings view so that every row uses the same spacing.",
                 "Refactorise la vue des réglages pour que chaque ligne ait le même espacement."),
            pick("Einkaufsliste: Milch, Brot, Tomaten, Kaffee.",
                 "Shopping list: milk, bread, tomatoes, coffee.",
                 "Liste de courses : lait, pain, tomates, café."),
        ]
        let hoursAgo = [0.2, 1.5, 3, 26, 28]
        let formatter = ISO8601DateFormatter()
        let history = zip(texts, hoursAgo).map { text, hours in
            ["id": UUID().uuidString, "date": formatter.string(from: Date.now.addingTimeInterval(-hours * 3600)), "text": text]
        }
        let dictionary: [String: Any] = [
            "woerter": ["Meyer", "Kubernetes", "SwiftUI", "Hugging Face", "PostgreSQL"],
            "ersetzungen": [["von": "get hub", "zu": "GitHub"], ["von": "mac OS", "zu": "macOS"]],
        ]
        try? JSONSerialization.data(withJSONObject: history).write(to: folder.appendingPathComponent("verlauf.json"))
        try? JSONSerialization.data(withJSONObject: dictionary).write(to: folder.appendingPathComponent("woerterbuch.json"))

        // Meetings nie in „Dokumente“ ablegen, auch nicht zum Zeichnen. Die Beispiele legt erst `snapshots` hinein.
        MeetingStore.rootOverride = folder.appendingPathComponent("Steno Meetings", isDirectory: true)
        meetingSamples = makeMeetingSamples()

        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
    }

    /// Sprache der Beispieldaten; ohne `--lang` Deutsch.
    private static var sampleLanguage = "de"

    private static func pick(_ german: String, _ english: String, _ french: String) -> String {
        switch sampleLanguage {
        case "en": return english
        case "fr": return french
        default: return german
        }
    }

    // MARK: Meetings

    /// Vier Meetings für die Ablage – das erste mit Zeitleiste und Bild – und dieselbe Zeitleiste für ein laufendes.
    private struct MeetingSamples {
        var files: [MeetingFile] = []
        var timeline: [MeetingEntry] = []
        var running = MeetingInfo(title: "", startedAt: .now, sources: [])
    }

    private static var meetingSamples = MeetingSamples()

    private static func makeMeetingSamples() -> MeetingSamples {
        let image = "3-46.png"
        let entries: [(TimeInterval, MeetingEntry.Kind)] = [
            (8, .speech(.you, pick("Guten Morgen zusammen. Wir haben knapp eine Dreiviertelstunde, ich würde mit dem Stand zum Relaunch anfangen.",
                                   "Good morning, everyone. We have about three quarters of an hour, so I'd start with where the relaunch stands.",
                                   "Bonjour à tous. Nous avons environ trois quarts d’heure, je propose de commencer par l’état du relancement."))),
            (24, .speech(.others, pick("Guten Morgen. Ja, gerne. Das Design ist seit gestern freigegeben, die Umsetzung startet diese Woche.",
                                       "Good morning. Sure. The design was signed off yesterday and the build starts this week.",
                                       "Bonjour. Volontiers. Le design est validé depuis hier, le développement commence cette semaine."))),
            (71, .note(pick("Design freigegeben (Montag)", "Design signed off (Monday)", "Design validé (lundi)"))),
            (96, .speech(.you, pick("Und wie sieht es mit den Texten aus? Die brauchen wir spätestens am Freitag.",
                                    "And what about the copy? We need it by Friday at the latest.",
                                    "Et où en sont les textes ? Il nous les faut vendredi au plus tard."))),
            (121, .speech(.others, pick("Die sind fast fertig. Ich schicke sie euch morgen früh, dann könnt ihr sie gleich einbauen.",
                                        "It's almost done. I'll send it over tomorrow morning so you can drop it in right away.",
                                        "Ils sont presque prêts. Je vous les envoie demain matin, vous pourrez les intégrer tout de suite."))),
            (133, .task(pick("Texte von Frau Meyer bis Freitag einfordern", "Get the copy from Ms. Meyer by Friday",
                             "Obtenir les textes de Mme Meyer d’ici vendredi"))),
            (190, .mark),
            (203, .speech(.others, pick("Bei den Bildern haben wir noch eine Frage zur Lizenz. Ich zeige euch kurz, worum es geht.",
                                        "We still have a question about the image licence. Let me show you what it's about.",
                                        "Pour les images, nous avons encore une question de licence. Je vous montre rapidement."))),
            (226, .image(image)),
            (241, .speech(.you, pick("Ah, okay. Das sieht gut aus. Kannst du mir das Dokument danach noch schicken?",
                                     "Ah, okay. That looks fine. Could you send me the document afterwards?",
                                     "Ah, d’accord. Ça a l’air bien. Tu peux m’envoyer le document ensuite ?"))),
            (268, .task(pick("Lizenz der Bilder klären", "Clear the image licence", "Clarifier la licence des images"))),
            (305, .speech(.others, pick("Mache ich. Dann noch kurz zum Budget: Wir liegen etwa fünf Prozent unter dem Plan.",
                                        "Will do. And a quick word on the budget: we're about five percent under plan.",
                                        "Je m’en occupe. Un mot encore sur le budget : nous sommes environ cinq pour cent sous le plan."))),
            (362, .note(pick("Budget: rund 5 % unter Plan", "Budget: about 5 % under plan", "Budget : environ 5 % sous le plan"))),
            (388, .speech(.you, pick("Sehr gut. Dann setzen wir uns nächste Woche wieder zusammen.",
                                     "Great. Then let's get together again next week.",
                                     "Très bien. Alors on se revoit la semaine prochaine."))),
        ]
        let timeline = entries.map { MeetingEntry(offset: $0.0, kind: $0.1) }

        let hour: TimeInterval = 3600
        let others = pick("Frau Meyer", "Ms. Meyer", "Mme Meyer")
        let both: MeetingSources = [.microphone, .systemAudio]
        let running = MeetingInfo(title: pick("Abstimmung Relaunch", "Relaunch sync", "Point relancement"), startedAt: .now.addingTimeInterval(-405),
                                  participants: pick("Frau Meyer, Herr Kaya", "Ms. Meyer, Mr. Kaya", "Mme Meyer, M. Kaya"), othersName: others, sources: both)
        var finished = running
        finished.startedAt = .now.addingTimeInterval(-2 * hour)
        finished.duration = 415
        let files: [MeetingFile] = [
            MeetingFile(info: finished, entries: timeline),
            MeetingFile(info: MeetingInfo(title: pick("Kundengespräch Meyer", "Client call Meyer", "Appel client Meyer"),
                                          startedAt: .now.addingTimeInterval(-26 * hour), duration: 47 * 60 + 12,
                                          participants: others, othersName: others, sources: both), entries: []),
            MeetingFile(info: MeetingInfo(title: pick("Sprint-Planung", "Sprint planning", "Planification du sprint"),
                                          startedAt: .now.addingTimeInterval(-74 * hour), duration: 72 * 60,
                                          participants: pick("Team Web", "Web team", "Équipe web"), sources: both), entries: []),
            MeetingFile(info: MeetingInfo(title: pick("Telefonat Steuerberatung", "Call with the accountant", "Appel avec le comptable"),
                                          startedAt: .now.addingTimeInterval(-9 * 24 * hour), duration: 23 * 60,
                                          participants: pick("Herr Schulz", "Mr. Schulz", "M. Schulz"), sources: .systemAudio), entries: []),
        ]
        return MeetingSamples(files: files, timeline: timeline, running: running)
    }

    /// Legt die Beispiele in die Ablage, zum ersten auch das Bild aus seiner Zeitleiste, und liefert das erste.
    private static func fileMeetingSamples() -> MeetingLibrary.Item? {
        var items: [MeetingLibrary.Item] = []
        for (index, file) in meetingSamples.files.enumerated() {
            let folder = MeetingStore.root.appendingPathComponent("\(index + 1) \(file.info.title)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder.appendingPathComponent(MeetingFile.imageFolder, isDirectory: true),
                                                     withIntermediateDirectories: true)
            try? MeetingStore.write(file, to: folder)
            items.append(MeetingLibrary.Item(folder: folder, info: file.info))
        }
        guard let first = items.first else { return nil }
        for case .image(let name) in meetingSamples.timeline.map(\.kind) {
            try? sampleImage()?.write(to: first.folder.appendingPathComponent(MeetingFile.imageFolder).appendingPathComponent(name))
        }
        return first
    }

    /// Ein erfundenes Bildschirmfoto: ein Fenster mit Säulendiagramm.
    private static func sampleImage() -> Data? {
        let picture = NSImage(size: NSSize(width: 960, height: 600), flipped: false) { rect in
            NSColor(white: 0.94, alpha: 1).setFill()
            rect.fill()
            let window = rect.insetBy(dx: 60, dy: 50)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: window, xRadius: 14, yRadius: 14).fill()
            NSColor(white: 0.86, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: window.minX + 30, y: window.maxY - 60, width: 260, height: 18), xRadius: 9, yRadius: 9).fill()
            let heights: [CGFloat] = [0.35, 0.55, 0.42, 0.78, 0.6, 0.9, 0.5]
            for (index, height) in heights.enumerated() {
                (index == 5 ? NSColor(srgbRed: 1, green: 0.29, blue: 0.24, alpha: 1) : NSColor(white: 0.82, alpha: 1)).setFill()
                let bar = NSRect(x: window.minX + 50 + CGFloat(index) * 112, y: window.minY + 40, width: 70, height: 340 * height)
                NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
            }
            return true
        }
        guard let tiff = picture.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private static func states() -> (setup: AppState, ready: AppState, models: ModelStore) {
        let models = ModelStore()
        models.pretendActive(ModelCatalog.recommended.file)
        let status = L("%@ – läuft komplett auf diesem Mac.", "Whisper Large v3 Turbo")
        let setup = AppState()
        setup.modelStatus = status
        setup.modelReady = true
        setup.modelName = "Whisper Large v3 Turbo"
        let ready = AppState()
        ready.modelStatus = status
        ready.modelReady = true
        ready.modelName = "Whisper Large v3 Turbo"
        ready.accessibility = true
        ready.microphone = true
        return (setup, ready, models)
    }

    // MARK: Prüfbilder

    private static func snapshots(into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (setup, ready, models) = states()
        for dark in [false, true] {  // solange die Ablage noch leer ist
            save(main(.meetings, ready, models, dark: dark), to: "\(folder)/main-meetings-empty-\(dark ? "dark" : "light").png")
        }
        let finished = fileMeetingSamples()
        let running = MeetingSession(state: .running, info: meetingSamples.running, entries: meetingSamples.timeline, folder: finished?.folder)
        let finishing = MeetingSession(state: .finishing, info: meetingSamples.running, entries: meetingSamples.timeline,
                                       folder: finished?.folder)
        var freshInfo = meetingSamples.running
        freshInfo.title = L("Meeting")
        freshInfo.startedAt = .now.addingTimeInterval(-12)
        freshInfo.participants = ""
        freshInfo.othersName = ""
        let started = MeetingSession(state: .running, info: freshInfo, entries: [])
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for page in Page.allCases {
                save(main(page, ready, models, dark: dark), to: "\(folder)/main-\(page)-\(suffix).png")
            }
            for page in [Page.settings, .dictionary, .start] {
                save(main(page, ready, models, dark: dark, height: 1400), to: "\(folder)/main-\(page)-tall-\(suffix).png")
            }
            save(main(.settings, ready, models, dark: dark, height: 900, scrolledBy: 3000), to: "\(folder)/main-settings-bottom-\(suffix).png")
            save(main(.start, setup, models, dark: dark), to: "\(folder)/main-setup-\(suffix).png")
            save(main(.start, setup, models, dark: dark, scrolledBy: 180), to: "\(folder)/main-setup-scrolled-\(suffix).png")
            save(main(.start, ready, models, dark: dark, width: 860, height: 540), to: "\(folder)/main-start-small-\(suffix).png")
            save(main(.start, ready, models, dark: dark, meeting: running), to: "\(folder)/main-start-running-\(suffix).png")
            save(main(.meetings, ready, models, dark: dark, meeting: running), to: "\(folder)/main-meetings-running-\(suffix).png")
            save(main(.meetings, ready, models, dark: dark, meeting: started), to: "\(folder)/main-meetings-started-\(suffix).png")
            save(main(.meetings, ready, models, dark: dark, width: 860, height: 540, meeting: running),
                 to: "\(folder)/main-meetings-running-small-\(suffix).png")
            save(main(.meetings, ready, models, dark: dark, meeting: finishing), to: "\(folder)/main-meetings-finishing-\(suffix).png")
            save(main(.meetings, ready, models, dark: dark, height: 1100, opened: finished), to: "\(folder)/main-meetings-detail-\(suffix).png")
            for step in Step.allCases {
                save(onboarding(step, setup, models, dark: dark), to: "\(folder)/onboarding-\(step.rawValue)-\(suffix).png")
            }
        }
        for style in [OverlayStyle.notch, .bubble] {
            for (name, state, hovering) in overlayStates {
                save(overlay(state, style: style, backdrop: true, hovering: hovering), to: "\(folder)/\(style)-\(name).png")
            }
            save(overlay(.meeting, style: style, backdrop: true, hovering: true, note: true), to: "\(folder)/\(style)-meeting-note.png")
        }
    }

    // MARK: Bilder für README und Webseite

    private static func marketing(into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (setup, ready, models) = states()
        // Mit abgelegten Beispielen zeigen Start- und Meetings-Seite die letzten Meetings.
        let filed = fileMeetingSamples()
        let running = MeetingSession(state: .running, info: meetingSamples.running, entries: meetingSamples.timeline, folder: filed?.folder)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for (name, page) in [("home", Page.start), ("meetings", .meetings), ("history", .history),
                                 ("dictionary", .dictionary), ("settings", .settings)] {
                save(main(page, ready, models, dark: dark, colorfulButtons: true), to: "\(folder)/app-\(name)-\(suffix).png")
            }
            save(main(.meetings, ready, models, dark: dark, colorfulButtons: true, meeting: running),
                 to: "\(folder)/app-meeting-running-\(suffix).png")
        }
        // Die Freigabe-Schritte zeigen, was man klickt; die übrigen den fertigen Zustand.
        let steps: [(String, Step, AppState)] = [("welcome", .welcome, ready), ("language", .language, ready),
                                                 ("microphone", .microphone, setup), ("accessibility", .accessibility, setup),
                                                 ("model", .model, ready), ("key", .practice, ready), ("done", .done, ready)]
        for (name, step, state) in steps {
            save(onboarding(step, state, models, dark: false, colorfulButtons: true), to: "\(folder)/onboarding-\(name).png")
        }
        for style in [OverlayStyle.notch, .bubble] {
            for (name, state, hovering) in overlayStates {
                save(overlay(state, style: style, backdrop: false, hovering: hovering), to: "\(folder)/\(style)-\(name).png")
            }
            save(overlay(.meeting, style: style, backdrop: false, hovering: true, note: true), to: "\(folder)/\(style)-meeting-note.png")
        }
        if let window = main(.start, ready, models, dark: false, colorfulButtons: true) {
            save(framed(window), to: "\(folder)/readme-hero.png")
        }
    }

    /// Name, Zustand und ob die Maus auf der Anzeige steht (beim Meeting: Notiz und Screenshot statt der Pegel).
    private static var overlayStates: [(String, OverlayModel.State, Bool)] {
        [("recording", .recording(handsFree: false), false), ("handsfree", .recording(handsFree: true), false), ("working", .working, false),
         ("meeting", .meeting, false), ("meeting-hover", .meeting, true),
         ("message", .message(L("Bereit – %@ halten oder zweimal tippen", HotKey.leftOption.shortName)), false),
         ("result", .result(L("Das ist ein Beispieltext, der ohne aktives Textfeld erscheint und kopiert werden kann.")), false)]
    }

    // MARK: Zeichnen

    private static func main(_ page: Page, _ state: AppState, _ models: ModelStore, dark: Bool,
                             width: CGFloat = 880, height: CGFloat = 620, colorfulButtons: Bool = false,
                             scrolledBy offset: CGFloat = 0, meeting: MeetingSession = MeetingSession(),
                             opened: MeetingLibrary.Item? = nil) -> NSBitmapImageRep? {
        let navigation = Navigation()
        navigation.page = page
        navigation.meeting = opened
        let window = MainWindow.makeWindow(RootView(navigation: navigation, state: state, models: models,
                                                    meeting: meeting, library: MeetingLibrary()))
        window.setContentSize(NSSize(width: width, height: height))
        return render(window, dark: dark, colorfulButtons: colorfulButtons) {
            // Ein geöffnetes Fenster hat beim Meeting den Cursor im Notizfeld; ohne Tastaturfokus würde sonst das erste Feld markiert.
            if meeting.state == .running { window.makeFirstResponder(textField(placeholder: L("Notiz hinzufügen …"), in: window.contentView)) }
            guard offset > 0, let scroll = firstScrollView(in: window.contentView) else { return }
            let end = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(scroll.contentView.bounds.minY + offset, end)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private static func textField(placeholder: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        for child in view.subviews { if let found = textField(placeholder: placeholder, in: child) { return found } }
        return nil
    }

    private static func firstScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = firstScrollView(in: child) { return found } }
        return nil
    }

    private static func onboarding(_ step: Step, _ state: AppState, _ models: ModelStore, dark: Bool,
                                   colorfulButtons: Bool = false) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: OnboardingView(state: state, models: models, finish: { _ in }, step: step))
        return render(window, dark: dark, colorfulButtons: colorfulButtons)
    }

    /// `note`: dazu das Notizfeld mit einem Beispieltext, wie nach einem Klick auf die Anzeige – unter der Notch, über der Blase.
    private static func overlay(_ state: OverlayModel.State, style: OverlayStyle, backdrop: Bool,
                                hovering: Bool = false, note: Bool = false) -> NSBitmapImageRep? {
        let model = OverlayModel()
        model.geometry = NotchGeometry(NSScreen.main, style: style)
        if !model.geometry.bubble, !model.geometry.hasNotch {
            // Ohne Notch am Bildschirm eine typische MacBook-Notch annehmen, damit das Bild stimmt.
            model.geometry.hasNotch = true
            model.geometry.notchWidth = 185
            model.geometry.barHeight = 32
        }
        model.levels = (0..<model.levels.count).map { CGFloat(0.2 + 0.6 * abs(sin(Double($0) * 0.7))) }
        // Ein Meeting läuft seit gut zwölf Minuten, beide Seiten sprechen. Die halbe Sekunde hält die Uhr auf allen Bildern
        // bei 12:35, obwohl bis zum Zeichnen etwa eine Sekunde vergeht.
        model.meetingRunning = true
        model.meetingStart = .now.addingTimeInterval(-(12 * 60 + 34.5))
        model.meetingSources = [.microphone, .systemAudio]
        model.meetingLevels = MeetingLevels(you: 0.45, others: 0.8)
        model.hovering = hovering
        model.state = state
        let view = ZStack {
            if backdrop { LinearGradient(colors: [Color(white: 0.78), Color(white: 0.58)], startPoint: .top, endPoint: .bottom) }
            OverlayView(model: model, overlay: nil)
        }
        let size = NSSize(width: 700, height: 200)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        if note {
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            hosting.frame = container.bounds
            container.addSubview(hosting)
            container.addSubview(quickNote(below: model.geometry, in: size))
            window.contentView = container
        } else {
            window.contentView = hosting
        }
        return render(window, dark: true, colorfulButtons: false)
    }

    /// Das Notizfeld aus `QuickNote`, hell und mit festem Grund: Ohne Fenster dahinter bliebe das Material durchsichtig.
    private static func quickNote(below geometry: NotchGeometry, in area: NSSize) -> NSView {
        let field = NSTextField()
        let content = QuickNote.makeContent(field)
        field.isEditable = false  // sonst nimmt das Fenster das Feld als erstes und der Text erscheint markiert
        field.isSelectable = false
        field.textColor = .labelColor
        field.stringValue = pick("Folgetermin im Mai vorschlagen", "Suggest a follow-up in May", "Proposer un rendez-vous de suivi en mai")
        let pill = geometry.size(for: .meeting)
        let y = geometry.bubble ? NotchOverlay.bubbleInset + pill.height + 8 : area.height - pill.height - 8 - QuickNote.size.height
        let frame = NSRect(x: (area.width - QuickNote.size.width) / 2, y: y, width: QuickNote.size.width, height: QuickNote.size.height)
        let card = NSView(frame: frame)
        card.appearance = NSAppearance(named: .aqua)
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        card.shadow = NSShadow()
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.25
        card.layer?.shadowRadius = 12
        card.layer?.shadowOffset = CGSize(width: 0, height: -4)
        content.frame = card.bounds
        (content as? NSVisualEffectView)?.state = .inactive
        card.addSubview(content)
        return card
    }

    /// Das Fenster liegt unsichtbar (durchsichtig, ohne Mausklicks) auf dem schärfsten Bildschirm –
    /// so entstehen Retina-Bilder, ohne dass auf dem Bildschirm etwas aufblitzt.
    private static func render(_ window: NSWindow, dark: Bool, colorfulButtons: Bool,
                               prepare: () -> Void = {}) -> NSBitmapImageRep? {
        let size = window.contentView?.frame.size ?? window.frame.size
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        if let screen {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                          y: screen.visibleFrame.maxY - window.frame.height))
        }
        window.orderFrontRegardless()
        window.setContentSize(size)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.7))
        prepare()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        defer { window.orderOut(nil) }
        guard let frame = window.contentView?.superview,  // Rahmen mit Titelleiste und Fensterknöpfen
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        if colorfulButtons { paintWindowButtons(of: window, in: frame, on: rep) }
        return rep
    }

    /// Das Fenster ist im Hintergrund, die Knöpfe wären grau – für die Bilder in den gewohnten Farben.
    private static func paintWindowButtons(of window: NSWindow, in frame: NSView, on rep: NSBitmapImageRep) {
        let colors: [(NSWindow.ButtonType, NSColor, NSColor)] = [
            (.closeButton, NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 0.88, green: 0.27, blue: 0.24, alpha: 1)),
            (.miniaturizeButton, NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.87, green: 0.63, blue: 0.14, alpha: 1)),
            (.zoomButton, NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.10, green: 0.67, blue: 0.16, alpha: 1)),
        ]
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return print("kein Zeichenkontext für die Fensterknöpfe") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context  // rechnet schon in Punkten, wie das Fenster
        for (type, fill, stroke) in colors {
            guard let button = window.standardWindowButton(type) else { continue }
            let rect = button.convert(button.bounds, to: frame)
            let diameter = min(rect.width, rect.height) - 1
            let circle = NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            let path = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Fensterbild mit runden Ecken und weichem Schatten auf transparentem Grund – für das README.
    private static func framed(_ image: NSBitmapImageRep) -> NSBitmapImageRep? {
        let padding = 90, radius: CGFloat = 26
        let width = image.pixelsWide + 2 * padding, height = image.pixelsHigh + 2 * padding
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep), let cgImage = image.cgImage else { return nil }
        let ctx = context.cgContext
        let rect = CGRect(x: padding, y: padding, width: image.pixelsWide, height: image.pixelsHigh)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(cgImage, in: rect)
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()
        return rep
    }

    private static func save(_ rep: NSBitmapImageRep?, to path: String) {
        guard let data = rep?.representation(using: .png, properties: [:]) else { return print("nicht gezeichnet: \(path)") }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
#endif
