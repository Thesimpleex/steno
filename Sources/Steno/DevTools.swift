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

        let german = language == nil || language == "de"
        let texts = german ? [
            "Kannst du mir bis Freitag die überarbeitete Präsentation schicken? Dann schaue ich sie mir am Wochenende an.",
            "Bitte fasse den Artikel in drei Stichpunkten zusammen und nenne die wichtigste Zahl.",
            "Termin mit Frau Meyer auf Donnerstag, 14 Uhr verschieben.",
            "Die Einstellungsseite so umbauen, dass jede Zeile denselben Abstand hat.",
            "Einkaufsliste: Milch, Brot, Tomaten, Kaffee.",
        ] : [
            "Can you send me the revised deck by Friday? I'll go through it over the weekend.",
            "Summarize the article in three bullet points and name the most important number.",
            "Move the meeting with Ms. Meyer to Thursday at 2 pm.",
            "Refactor the settings view so that every row uses the same spacing.",
            "Shopping list: milk, bread, tomatoes, coffee.",
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

        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
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
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for page in Page.allCases {
                save(main(page, ready, models, dark: dark), to: "\(folder)/main-\(page)-\(suffix).png")
            }
            for page in [Page.settings, .dictionary] {
                save(main(page, ready, models, dark: dark, height: 1400), to: "\(folder)/main-\(page)-tall-\(suffix).png")
            }
            save(main(.start, setup, models, dark: dark), to: "\(folder)/main-setup-\(suffix).png")
            save(main(.start, setup, models, dark: dark, scrolledBy: 180), to: "\(folder)/main-setup-scrolled-\(suffix).png")
            save(main(.start, ready, models, dark: dark, width: 780, height: 540), to: "\(folder)/main-start-small-\(suffix).png")
            for step in Step.allCases {
                save(onboarding(step, setup, models, dark: dark), to: "\(folder)/onboarding-\(step.rawValue)-\(suffix).png")
            }
        }
        for style in [OverlayStyle.notch, .bubble] {
            for (name, state) in overlayStates {
                save(overlay(state, style: style, backdrop: true), to: "\(folder)/\(style)-\(name).png")
            }
        }
    }

    // MARK: Bilder für README und Webseite

    private static func marketing(into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let (setup, ready, models) = states()
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for (name, page) in [("home", Page.start), ("history", .history), ("dictionary", .dictionary), ("settings", .settings)] {
                save(main(page, ready, models, dark: dark, colorfulButtons: true), to: "\(folder)/app-\(name)-\(suffix).png")
            }
        }
        // Die Freigabe-Schritte zeigen, was man klickt; die übrigen den fertigen Zustand.
        let steps: [(String, Step, AppState)] = [("welcome", .welcome, ready), ("language", .language, ready),
                                                 ("microphone", .microphone, setup), ("accessibility", .accessibility, setup),
                                                 ("model", .model, ready), ("key", .practice, ready), ("done", .done, ready)]
        for (name, step, state) in steps {
            save(onboarding(step, state, models, dark: false, colorfulButtons: true), to: "\(folder)/onboarding-\(name).png")
        }
        for style in [OverlayStyle.notch, .bubble] {
            for (name, state) in overlayStates {
                save(overlay(state, style: style, backdrop: false), to: "\(folder)/\(style)-\(name).png")
            }
        }
        if let window = main(.start, ready, models, dark: false, colorfulButtons: true) {
            save(framed(window), to: "\(folder)/readme-hero.png")
        }
    }

    private static var overlayStates: [(String, OverlayModel.State)] {
        [("recording", .recording(handsFree: false)), ("handsfree", .recording(handsFree: true)), ("working", .working),
         ("message", .message(L("Bereit – %@ halten oder zweimal tippen", HotKey.leftOption.shortName))),
         ("result", .result(L("Das ist ein Beispieltext, der ohne aktives Textfeld erscheint und kopiert werden kann.")))]
    }

    // MARK: Zeichnen

    private static func main(_ page: Page, _ state: AppState, _ models: ModelStore, dark: Bool,
                             width: CGFloat = 880, height: CGFloat = 620, colorfulButtons: Bool = false,
                             scrolledBy offset: CGFloat = 0) -> NSBitmapImageRep? {
        let navigation = Navigation()
        navigation.page = page
        let window = MainWindow.makeWindow(RootView(navigation: navigation, state: state, models: models,
                                                    meeting: MeetingSession(), library: MeetingLibrary()))
        window.setContentSize(NSSize(width: width, height: height))
        return render(window, dark: dark, colorfulButtons: colorfulButtons) {
            guard offset > 0, let scroll = firstScrollView(in: window.contentView) else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + offset))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
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

    private static func overlay(_ state: OverlayModel.State, style: OverlayStyle, backdrop: Bool) -> NSBitmapImageRep? {
        let model = OverlayModel()
        model.geometry = NotchGeometry(NSScreen.main, style: style)
        if !model.geometry.bubble, !model.geometry.hasNotch {
            // Ohne Notch am Bildschirm eine typische MacBook-Notch annehmen, damit das Bild stimmt.
            model.geometry.hasNotch = true
            model.geometry.notchWidth = 185
            model.geometry.barHeight = 32
        }
        model.levels = (0..<model.levels.count).map { CGFloat(0.2 + 0.6 * abs(sin(Double($0) * 0.7))) }
        model.state = state
        let view = ZStack {
            if backdrop { LinearGradient(colors: [Color(white: 0.78), Color(white: 0.58)], startPoint: .top, endPoint: .bottom) }
            OverlayView(model: model, overlay: nil)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = NSHostingView(rootView: view.frame(width: 700, height: 200))
        return render(window, dark: true, colorfulButtons: false)
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
