import AppKit
import SwiftUI

/// Wie die Aufnahme angezeigt wird. Automatisch: an der Notch, wenn der Bildschirm eine hat, sonst als Blase.
enum OverlayStyle: String, CaseIterable, Identifiable {
    case automatic, notch, bubble

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic: return L("Automatisch")
        case .notch: return L("An der Notch")
        case .bubble: return L("Blase")
        }
    }

    var detail: String {
        switch self {
        case .automatic: return L("An der Notch, wenn dein Bildschirm eine hat – sonst als Blase unten.")
        case .notch: return L("Wächst aus der Notch – ohne Notch vom oberen Bildschirmrand.")
        case .bubble: return L("Schwebt unten in der Mitte über dem Dock.")
        }
    }
}

/// Die schwarze Anzeige: wächst aus der Notch heraus oder schwebt als Blase über dem Dock.
final class NotchOverlay {
    let model = OverlayModel()
    var style = OverlayStyle.automatic
    /// Klick auf die Meeting-Anzeige; übergibt, wo sie auf dem Bildschirm steht.
    var onNote: ((NSRect) -> Void)?
    var onScreenshot: (() -> Void)?
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private var generation = 0  // jede neue Anzeige macht ältere, noch ausstehende Animationen ungültig
    private var mouseTimer: Timer?
    private var previewTimer: Timer?
    private var hovering = false
    private static let canvas = CGSize(width: 700, height: 240)
    /// Abstand der Blase zum unteren Rand des Fensters – Platz für ihren Schatten.
    static let bubbleInset: CGFloat = 16

    init() {
        panel = EdgePanel(contentRect: NSRect(origin: .zero, size: Self.canvas),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)  // über der Menüleiste
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: OverlayView(model: model, overlay: nil))
        panel.contentView = host
        host.rootView = OverlayView(model: model, overlay: self)
    }

    func showRecording(handsFree: Bool, since start: Date = .now) {
        model.startedAt = start
        model.levels = Array(repeating: 0, count: model.levels.count)
        model.willSend = false
        show(.recording(handsFree: handsFree))
    }

    /// Return während der Aufnahme: ein kleines ↩︎ zeigt, dass danach abgeschickt wird.
    func showSendHint() {
        withAnimation(.easeOut(duration: 0.15)) { model.willSend = true }
    }

    /// Legt das Fenster beim Start an und zeichnet es einmal unsichtbar – so muss das erste Einblenden nicht darauf warten.
    func warmUp() {
        guard let screen = NSScreen.main, !panel.isVisible else { return }
        model.geometry = NotchGeometry(screen, style: style)
        panel.setFrame(frame(for: model.geometry, on: screen), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let current = generation
        DispatchQueue.main.async {
            guard self.generation == current else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    func showWorking() { show(.working) }

    func showResult(_ text: String, copied: Bool = false) {
        model.copied = copied
        show(.result(text))
        hide(after: 15)
    }

    func showMessage(_ text: String, seconds: Double = 2.5) {
        show(.message(text))
        hide(after: seconds)
        announce(text)
    }

    /// VoiceOver liest Meldungen der Anzeige vor.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Der leise Hinweis, solange ein Meeting läuft. Diktat-Anzeigen legen sich vorübergehend darüber;
    /// `hide()` führt danach hierher zurück.
    func showMeeting(since start: Date, sources: MeetingSources) {
        model.meetingStart = start
        model.meetingSources = sources
        model.meetingLevels = MeetingLevels()
        model.meetingRunning = true
        if model.state == .hidden { show(.meeting) }
    }

    func endMeeting() {
        model.meetingRunning = false
        if model.state == .meeting { hide() }
    }

    /// Kurze Bestätigung. Ein laufendes Diktat und ein angezeigtes Ergebnis bleiben stehen.
    func confirm(_ text: String) {
        switch model.state {
        case .hidden, .meeting, .message: showMessage(text, seconds: 1.5)
        case .recording, .working, .result: break
        }
    }

    /// Kurze Vorführung mit erfundenem Pegel – für die Auswahl in den Einstellungen.
    func preview() {
        switch model.state {
        case .hidden, .meeting, .message: break
        case .recording where previewTimer != nil: break
        default: return  // nie über eine echte Aufnahme oder ein Ergebnis legen
        }
        showRecording(handsFree: false)
        var tick = 0
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] timer in
            tick += 1
            self?.model.push(level: Float(0.25 + 0.55 * abs(sin(Double(tick) * 0.45)) * abs(cos(Double(tick) * 0.17))))
            if tick >= 45 {
                timer.invalidate()
                self?.hide()
            }
        }
    }

    var isShowingRecording: Bool {
        if case .recording = model.state { return true }
        return false
    }

    func hide() {
        hideWork?.cancel()
        stopPreview()
        generation += 1
        stopMouseTracking()
        guard model.state != .hidden || panel.isVisible else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { model.state = model.resting }
        if model.state.acceptsMouse { startMouseTracking() }
        let work = DispatchWorkItem { [weak self] in
            if self?.model.state == .hidden { self?.panel.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    fileprivate func copyResult() {
        guard case .result(let text) = model.state else { return }
        TextInsertion.copy(text)
        model.copied = true
        hide(after: 0.9)
    }

    fileprivate func openNote() {
        guard model.state == .meeting else { return }
        onNote?(activeArea)
    }

    fileprivate func takeScreenshot() {
        guard model.state == .meeting else { return }
        onScreenshot?()
    }

    private func show(_ state: OverlayModel.State) {
        hideWork?.cancel()
        stopPreview()  // eine echte Aufnahme beendet die Vorführung, ohne selbst ausgeblendet zu werden
        generation += 1
        let current = generation
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let geometry = NotchGeometry(screen, style: style)
        // Anderer Bildschirm oder Stil: erst die Ausgangsgröße dort zeichnen, dann aufziehen. Sonst ist sie schon
        // gezeichnet, und das Aufziehen beginnt gleich im nächsten Bild.
        let reset = geometry != model.geometry || (model.state != .hidden && !panel.isVisible)
        if model.state == .hidden || !panel.isVisible || reset {
            if reset {
                model.geometry = geometry
                model.state = .hidden
            }
            panel.setFrame(frame(for: geometry, on: screen), display: false)
            panel.alphaValue = 1  // falls das Vorzeichnen beim Start noch nicht fertig ist
            panel.orderFrontRegardless()
        }
        let open = { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { self.model.state = state } }
        if reset {
            DispatchQueue.main.async { if self.generation == current { open() } }
        } else {
            open()
        }
        if state.acceptsMouse { startMouseTracking() } else { stopMouseTracking() }
    }

    private func frame(for geometry: NotchGeometry, on screen: NSScreen) -> NSRect {
        let origin = geometry.bubble
            ? CGPoint(x: geometry.centerX - Self.canvas.width / 2, y: geometry.floor + 4)
            : CGPoint(x: geometry.centerX - Self.canvas.width / 2, y: screen.frame.maxY - Self.canvas.height)
        return NSRect(origin: origin, size: Self.canvas)
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    private func hide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Die schwarze Fläche auf dem Bildschirm – nur dort nimmt das Fenster Klicks an.
    private var activeArea: NSRect {
        let size = model.geometry.size(for: model.state)
        let frame = panel.frame
        let y = model.geometry.bubble ? frame.minY + Self.bubbleInset : frame.maxY - size.height
        return NSRect(x: frame.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }

    /// Das Fenster ist größer als die schwarze Fläche. Klicks nimmt es nur dort an, wo die Fläche ist –
    /// daneben bleibt alles darunter bedienbar. Solange die Maus darauf ist, bleibt das Ergebnis stehen bzw. zeigt die
    /// Meeting-Anzeige ihre Knöpfe.
    private func startMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let inside = self.activeArea.contains(NSEvent.mouseLocation)
            if self.panel.ignoresMouseEvents == inside { self.panel.ignoresMouseEvents = !inside }
            guard inside != self.hovering else { return }
            self.hovering = inside
            if self.model.state == .meeting {
                self.model.hovering = inside
            } else if !self.model.copied {
                if inside { self.hideWork?.cancel() } else { self.hide(after: 5) }
            }
        }
        mouseTimer?.tolerance = 0.02
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        hovering = false
        model.hovering = false
        panel.ignoresMouseEvents = true
    }
}

final class OverlayModel: ObservableObject {
    enum State: Equatable {
        case hidden
        case recording(handsFree: Bool)
        case working
        case result(String)
        case message(String)
        /// Der leise Dauerhinweis, solange ein Meeting läuft.
        case meeting

        /// Nur das Ergebnis und die Meeting-Anzeige nehmen Klicks an. Alles andere – vor allem ein Diktat – lässt die
        /// Menüleiste darunter bedienbar.
        var acceptsMouse: Bool {
            switch self {
            case .result, .meeting: return true
            case .hidden, .recording, .working, .message: return false
            }
        }
    }

    @Published var state = State.hidden
    @Published var levels = [CGFloat](repeating: 0, count: 16)
    @Published var copied = false
    @Published var startedAt = Date.now
    @Published var geometry = NotchGeometry(nil)
    @Published var meetingRunning = false
    /// Start und Quellen bleiben stehen, bis das nächste Meeting beginnt – so springt die Zeit beim Ausblenden nicht.
    @Published var meetingStart = Date.now
    @Published var meetingSources: MeetingSources = [.microphone, .systemAudio]
    @Published var meetingLevels = MeetingLevels()
    /// Nach dem Einfügen wird abgeschickt.
    @Published var willSend = false
    /// Die Maus steht auf der Meeting-Anzeige: statt der Pegel erscheinen Notiz und Screenshot.
    @Published var hovering = false

    func push(level: Float) {
        levels.removeFirst()
        levels.append(CGFloat(level))
    }

    /// Wohin die Anzeige zurückkehrt, wenn nichts anderes zu zeigen ist.
    var resting: State { meetingRunning ? .meeting : .hidden }
}

struct NotchGeometry: Equatable {
    var hasNotch = false
    var notchWidth: CGFloat = 0
    var barHeight: CGFloat = 32  // Höhe der Notch bzw. der Menüleiste
    var centerX: CGFloat = 0
    /// Als Blase über dem Dock statt oben an der Notch.
    var bubble = false
    /// Unterkante des nutzbaren Bereichs (über dem Dock).
    var floor: CGFloat = 0

    init(_ screen: NSScreen?, style: OverlayStyle = .automatic) {
        guard let screen else { return }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = right.minX - left.maxX
            barHeight = screen.safeAreaInsets.top
            centerX = (left.maxX + right.minX) / 2
        } else {
            barHeight = max(28, screen.frame.maxY - screen.visibleFrame.maxY)
            centerX = screen.frame.midX
        }
        bubble = style == .bubble || (style == .automatic && !hasNotch)
        if bubble {
            centerX = screen.visibleFrame.midX
            floor = screen.visibleFrame.minY
        }
    }

    func size(for state: OverlayModel.State) -> CGSize {
        if bubble {
            switch state {
            case .hidden: return CGSize(width: 150, height: 40)
            case .recording, .working: return CGSize(width: 196, height: 40)
            case .meeting: return CGSize(width: 132, height: 32)
            case .message: return CGSize(width: 380, height: 54)
            case .result: return CGSize(width: 500, height: 92)
            }
        }
        let compact = CGSize(width: (hasNotch ? notchWidth : 70) + 2 * 78 + 2 * NotchShape.ear, height: barHeight)
        switch state {
        case .hidden: return hasNotch ? CGSize(width: notchWidth, height: barHeight) : CGSize(width: compact.width, height: 0)
        case .recording, .working, .meeting: return compact
        case .message: return CGSize(width: max(compact.width, 380), height: barHeight + 52)
        case .result: return CGSize(width: max(compact.width, 460), height: barHeight + 92)
        }
    }
}

/// Darf über die Menüleiste bis an den Bildschirmrand.
private final class EdgePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}

/// Der Kopieren-Knopf reagiert schon beim ersten Klick, ohne Steno nach vorn zu holen.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Form

/// Schwarze Fläche mit nach außen gebogenen oberen Ecken – dadurch wirkt sie wie aus der Notch gewachsen.
struct NotchShape: Shape {
    static let ear: CGFloat = 9
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), cornerRadius) }
        set { (width, height, cornerRadius) = (newValue.first.first, newValue.first.second, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(width, 1), h = max(height, 0)
        let left = rect.midX - w / 2, right = left + w
        let ear = min(Self.ear, h / 2, w / 4)
        let r = max(0, min(cornerRadius, h - ear, (w - 2 * ear) / 2))
        var path = Path()
        path.move(to: CGPoint(x: left, y: 0))
        path.addQuadCurve(to: CGPoint(x: left + ear, y: ear), control: CGPoint(x: left + ear, y: 0))
        path.addLine(to: CGPoint(x: left + ear, y: h - r))
        path.addQuadCurve(to: CGPoint(x: left + ear + r, y: h), control: CGPoint(x: left + ear, y: h))
        path.addLine(to: CGPoint(x: right - ear - r, y: h))
        path.addQuadCurve(to: CGPoint(x: right - ear, y: h - r), control: CGPoint(x: right - ear, y: h))
        path.addLine(to: CGPoint(x: right - ear, y: ear))
        path.addQuadCurve(to: CGPoint(x: right, y: 0), control: CGPoint(x: right - ear, y: 0))
        path.closeSubpath()
        return path
    }
}

// MARK: - Inhalt

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    weak var overlay: NotchOverlay?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGSize { model.geometry.size(for: model.state) }
    private var expanded: Bool {
        switch model.state {
        case .result, .message: return true
        default: return false
        }
    }

    var body: some View {
        if model.geometry.bubble { bubble } else { notch }
    }

    // MARK: An der Notch

    private var notch: some View {
        ZStack(alignment: .top) {
            NotchShape(width: size.width, height: size.height, cornerRadius: expanded ? 22 : 12)
                .fill(.black)
                .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 14, y: 6)

            if model.state != .hidden {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        leading.frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: model.geometry.hasNotch ? model.geometry.notchWidth : 20)
                        trailing.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: model.geometry.barHeight)

                    // Unter der Leiste mittig, statt oben zu kleben.
                    if expanded { detail.frame(maxHeight: .infinity).transition(.opacity.combined(with: .move(edge: .top))) }
                }
                .frame(width: size.width - 2 * NotchShape.ear - 16, height: size.height, alignment: .top)
                .foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Ein Klick irgendwo auf die schwarze Fläche öffnet die Notiz – außerhalb davon kommen ohnehin keine Klicks an.
        .contentShape(NotchShape(width: size.width, height: size.height, cornerRadius: 12))
        .onTapGesture { overlay?.openNote() }
    }

    // MARK: Als Blase

    private var bubble: some View {
        let visible = model.state != .hidden
        // Bei halber Höhe als Radius sauber rund – „continuous“ zeichnet dort feine Striche an den Enden.
        let shape = RoundedRectangle(cornerRadius: expanded ? 20 : size.height / 2, style: expanded ? .continuous : .circular)
        return ZStack {
            shape.fill(.black)
                .overlay(shape.strokeBorder(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            if visible {
                bubbleContent.foregroundStyle(.white).transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .onTapGesture { overlay?.openNote() }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.9, anchor: .bottom)
        .padding(.bottom, NotchOverlay.bubbleInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder private var bubbleContent: some View {
        switch model.state {
        case .recording, .working, .meeting:
            HStack(spacing: 10) {
                leading
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
        case .message(let text):
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").font(.system(size: 12))
                Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            .padding(.horizontal, 18)
        case .result:
            detail
        case .hidden:
            EmptyView()
        }
    }

    // MARK: Bausteine

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .recording(let handsFree):
            HStack(spacing: 6) {
                if handsFree {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                } else if model.willSend {
                    // Anstelle des Punkts: Neben der Zeit ist kein Platz mehr, sobald sie zweistellige Minuten hat.
                    Image(systemName: "return").font(.system(size: 9, weight: .bold)).foregroundStyle(PulsingDot.red)
                } else {
                    PulsingDot()
                }
                Elapsed(since: model.startedAt)
            }
        case .working:
            Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).symbolEffect(.variableColor.iterative)
        case .meeting:
            HStack(spacing: 6) {
                PulsingDot(pulsing: false)
                Elapsed(since: model.meetingStart)
            }
        case .message:
            Image(systemName: "info.circle.fill").font(.system(size: 11))
        case .hidden, .result:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.state {
        case .recording: LevelHistory(levels: model.levels, dimmed: false)
        case .working: LevelHistory(levels: model.levels, dimmed: true)
        case .meeting:
            ZStack(alignment: .trailing) {
                if model.hovering {
                    meetingButtons.transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                } else {
                    MeetingLevelBars(levels: model.meetingLevels, sources: model.meetingSources).transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.hovering)
        default: EmptyView()
        }
    }

    private var meetingButtons: some View {
        HStack(spacing: 3) {
            MeetingButton(symbol: "square.and.pencil", label: L("Notiz")) { overlay?.openNote() }
            MeetingButton(symbol: "camera.viewfinder", label: L("Screenshot")) { overlay?.takeScreenshot() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.state {
        case .message(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
        case .result(let text):
            HStack(spacing: 12) {
                Text(text)
                    .font(.system(size: 12.5))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { overlay?.copyResult() } label: {
                    Label(model.copied ? L("Kopiert") : L("Kopieren"), systemImage: model.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.white.opacity(model.copied ? 0.25 : 0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                Button { overlay?.hide() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Schließen"))
            }
            .padding(model.geometry.bubble ? EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 14)
                                           : EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8))
        default:
            EmptyView()
        }
    }
}

private struct PulsingDot: View {
    var pulsing = true
    static let red = Color(red: 1, green: 0.27, blue: 0.23)
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(Self.red)
            .frame(width: 7, height: 7)
            .opacity(bright || !pulsing ? 1 : 0.35)
            .onAppear {
                if pulsing { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { bright = true } }
            }
    }
}

struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(MeetingMarkdown.timestamp(context.date.timeIntervalSince(since)))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Kleiner runder Knopf auf der Meeting-Anzeige; hellt unter der Maus leicht auf.
private struct MeetingButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(.white.opacity(hovering ? 0.22 : 0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Zwei winzige Pegel: links du, rechts die anderen. Eine Quelle, die nicht läuft, bekommt keinen.
private struct MeetingLevelBars: View {
    let levels: MeetingLevels
    let sources: MeetingSources

    var body: some View {
        HStack(spacing: 3) {
            if sources.contains(.microphone) { bar(levels.you) }
            if sources.contains(.systemAudio) { bar(levels.others) }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.1), value: levels)
    }

    private func bar(_ level: Float) -> some View {
        Capsule().fill(.white.opacity(0.6)).frame(width: 3, height: 3 + 13 * CGFloat(min(1, level)))
    }
}

/// Laufende Pegelkurve: der neueste Wert kommt rechts hinein.
private struct LevelHistory: View {
    let levels: [CGFloat]
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(dimmed ? 0.35 : 0.55 + 0.45 * Double(i) / Double(levels.count)))
                    .frame(width: 2.5, height: 3 + 15 * min(1, levels[i]))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}
