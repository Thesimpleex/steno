import AppKit
import SwiftUI

enum Page: Hashable, CaseIterable {
    case start, meetings, history, dictionary, settings

    var title: String {
        switch self {
        case .start: return L("Start")
        case .meetings: return L("Meetings")
        case .history: return L("Verlauf")
        case .dictionary: return L("Wörterbuch")
        case .settings: return L("Einstellungen")
        }
    }

    var symbol: String {
        switch self {
        case .start: return "house"
        case .meetings: return "person.2"
        case .history: return "clock"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

final class MainWindow: NSObject, NSWindowDelegate {
    private let state: AppState
    private let models: ModelStore
    private let meeting: MeetingSession
    private let library: MeetingLibrary
    private let navigation = Navigation()
    private var window: NSWindow?

    init(state: AppState, models: ModelStore, meeting: MeetingSession, library: MeetingLibrary) {
        self.state = state
        self.models = models
        self.meeting = meeting
        self.library = library
    }

    func show(_ page: Page) {
        navigation.page = page
        if window == nil {
            let window = Self.makeWindow(RootView(navigation: navigation, state: state, models: models,
                                                  meeting: meeting, library: library))
            window.delegate = self
            window.center()
            self.window = window
        }
        // Solange das Fenster offen ist, mit Dock-Symbol und über ⌘⇥ erreichbar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Eine leere Symbolleiste macht die Titelleiste 52 pt hoch: Die Fensterknöpfe sitzen dann auf einer Linie
    /// mit den eigenen Tabs, die SwiftUI selbst oben ins Fenster zeichnet.
    static func makeWindow<Content: View>(_ content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Steno"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "steno.main")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 540)
        window.contentView = NSHostingView(rootView: content)
        return window
    }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        hideDockIconIfLastWindow(closing: notification.object as? NSWindow)
    }
}

final class Navigation: ObservableObject {
    @Published var page = Page.start
    /// Das geöffnete Meeting auf der Meetings-Seite; ohne eines zeigt die Seite die Liste.
    @Published var meeting: MeetingLibrary.Item?
}

struct RootView: View {
    @ObservedObject var navigation: Navigation
    @ObservedObject var state: AppState
    let models: ModelStore
    @ObservedObject var meeting: MeetingSession
    @ObservedObject var library: MeetingLibrary

    var body: some View {
        VStack(spacing: 0) {
            // Liegt über dem Inhalt: macOS lässt Scrollbereiche sonst unter die Titelleiste laufen.
            TopBar(navigation: navigation, state: state, meeting: meeting)
                .background(Theme.page)
                .zIndex(1)
            Group {
                switch navigation.page {
                case .start: StartPage(state: state, navigation: navigation)
                case .meetings: MeetingsPage(navigation: navigation, meeting: meeting, library: library)
                case .history: HistoryPage(navigation: navigation)
                case .dictionary: DictionaryPage()
                case .settings: SettingsPage(state: state, models: models)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .background(Theme.page)
        .ignoresSafeArea(edges: .top)
        .tint(Theme.accent)
        // Nach dem Meeting soll die Liste mit dem neuen Eintrag erscheinen, nicht ein zuvor geöffnetes Meeting.
        .onChange(of: meeting.state) { navigation.meeting = nil }
    }
}

/// Die Leiste oben: Marke links, Seiten als Kapsel-Tabs in der Mitte, Status rechts.
private struct TopBar: View {
    @ObservedObject var navigation: Navigation
    @ObservedObject var state: AppState
    @ObservedObject var meeting: MeetingSession
    @Namespace private var selection

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Color.clear.frame(width: 62)  // Platz für die Fensterknöpfe
                WaveMark(bars: .primary).frame(width: 16, height: 15)
                Text("Steno").font(.system(size: 14, weight: .bold)).tracking(-0.2)
                Spacer()
                status
            }
            tabs
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                let selected = navigation.page == page
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { navigation.page = page }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: page.symbol).font(.system(size: 11.5, weight: .semibold))
                        Text(page.title).font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .foregroundStyle(selected ? Theme.onInk : Color.secondary)
                    .background {
                        if selected { Capsule().fill(Theme.ink).matchedGeometryEffect(id: "tab", in: selection) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .help(page.title + " (⌘\(index + 1))")
            }
        }
        .padding(3)
        .background(Theme.well, in: Capsule())
    }

    /// Bereitschaft der App – oder, solange aufgenommen wird, ein Hinweis darauf, auf jeder Seite sichtbar.
    private var status: some View {
        let recording = meeting.state == .running
        return Button { withAnimation { navigation.page = recording ? .meetings : .start } } label: {
            HStack(spacing: 6) {
                if recording { RecordingDot() } else { StatusDot(ok: state.ready) }
                Text(recording ? L("Meeting läuft") : state.ready ? L("Bereit") : L("Einrichtung offen"))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.well, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Einheitlicher Seitenrahmen: gleiche Ränder und Breite auf jeder Seite.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .padding(EdgeInsets(top: 30, leading: 32, bottom: 40, trailing: 32))
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Überschrift mit Inhalt darunter.
struct TitledGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title)
            content
        }
    }
}
