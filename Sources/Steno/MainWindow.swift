import AppKit
import SwiftUI

enum Page: Hashable, CaseIterable {
    case start, history, dictionary, settings

    var title: String {
        switch self {
        case .start: return L("Start")
        case .history: return L("Verlauf")
        case .dictionary: return L("Wörterbuch")
        case .settings: return L("Einstellungen")
        }
    }

    var symbol: String {
        switch self {
        case .start: return "house"
        case .history: return "clock"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

final class MainWindow: NSObject, NSWindowDelegate {
    private let state: AppState
    private let models: ModelStore
    private let navigation = Navigation()
    private var window: NSWindow?

    init(state: AppState, models: ModelStore) {
        self.state = state
        self.models = models
    }

    func show(_ page: Page) {
        navigation.page = page
        if window == nil {
            let window = Self.makeWindow(RootView(navigation: navigation, state: state, models: models))
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
}

struct RootView: View {
    @ObservedObject var navigation: Navigation
    @ObservedObject var state: AppState
    let models: ModelStore

    var body: some View {
        VStack(spacing: 0) {
            // Liegt über dem Inhalt: macOS lässt Scrollbereiche sonst unter die Titelleiste laufen.
            TopBar(navigation: navigation, state: state)
                .background(Theme.page)
                .zIndex(1)
            Group {
                switch navigation.page {
                case .start: StartPage(state: state, navigation: navigation)
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
    }
}

/// Die Leiste oben: Marke links, Seiten als Kapsel-Tabs in der Mitte, Status rechts.
private struct TopBar: View {
    @ObservedObject var navigation: Navigation
    @ObservedObject var state: AppState
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

    private var status: some View {
        Button { withAnimation { navigation.page = .start } } label: {
            HStack(spacing: 6) {
                StatusDot(ok: state.ready)
                Text(state.ready ? L("Bereit") : L("Einrichtung offen"))
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

private extension String {
    var wordCount: Int { split(whereSeparator: \.isWhitespace).count }
}

// MARK: - Start

private struct StartPage: View {
    @ObservedObject var state: AppState
    let navigation: Navigation
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        PageScroll {
            hero
            if !state.ready { setup }

            TitledGroup(title: L("So diktierst du")) {
                HStack(alignment: .top, spacing: 12) {
                    mode([key], L("Halten"), L("Taste halten, sprechen, loslassen – der Text erscheint am Cursor."))
                    mode([key, key], L("Freihändig"), L("Zweimal tippen und frei sprechen. Einmal tippen beendet."))
                    mode(["⌃", "⌥", "V"], L("Erneut einfügen"), L("Fügt das letzte Diktat erneut ein – etwa wenn es im falschen Fenster landete."))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if history.retentionDays > 0 {
                TitledGroup(title: L("Dein Verlauf")) {
                    HStack(spacing: 0) {
                        stat(history.entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.text.wordCount },
                             L("Wörter heute"))
                        divider
                        stat(history.entries.reduce(0) { $0 + $1.text.wordCount }, L("Wörter im Verlauf"))
                        divider
                        stat(history.entries.count, L("Diktate im Verlauf"))
                    }
                    .card(padding: 18)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 12))
                Text(L("Zu früh losgelassen? Sofort wieder drücken, dann läuft die Aufnahme weiter (ab 3 s Aufnahmedauer). Esc bricht ab – innerhalb von 3 s erneut drücken, um fortzusetzen. Ohne aktives Textfeld wartet der Text in der Anzeige. ⌘Q schließt nur das Fenster, ⌥⌘Q beendet Steno."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private var key: String { state.hotKey.symbol }

    /// Schwarze Karte im Stil von Logo und Notch – das Erste, was man sieht.
    private var hero: some View {
        HStack(spacing: 20) {
            WaveMark().frame(width: 44, height: 40).frame(width: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text("Steno").font(.system(size: 26, weight: .bold)).tracking(-0.3)
                HStack(spacing: 7) {
                    StatusDot(ok: state.ready)
                    Text(state.ready ? L("Bereit") + " · " + (state.modelName ?? state.modelStatus)
                         : state.modelName.map { L("Einrichtung offen") + " · " + $0 } ?? state.modelStatus)
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    if state.ready {
                        Text(L("lokal"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                KeyCap(key: key, large: true, onDark: true)
                Text(L("halten und sprechen")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .background {
            ZStack {
                LinearGradient(colors: [Color(white: 0.15), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.accent.opacity(0.06), .clear], center: UnitPoint(x: 0.07, y: 0.5),
                               startRadius: 0, endRadius: 110)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }
    }

    private var steps: [(done: Bool, title: String, detail: String, button: String, action: () -> Void)] {
        [(state.modelReady, L("Sprachmodell"), state.modelStatus, L("Auswählen …"), { navigation.page = .settings }),
         (state.accessibility, L("Bedienungshilfen"), L("Damit Steno die Taste erkennt und Text einfügen kann."),
          L("Erlauben"), state.requestAccessibility),
         (state.microphone, L("Mikrofon"), L("Wird nur während einer Aufnahme genutzt."), L("Erlauben"), state.requestMicrophone)]
    }

    private var setup: some View {
        let steps = self.steps
        let done = steps.filter(\.done).count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Einrichtung abschließen")).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(L("%lld von %lld erledigt", done, steps.count)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    Capsule().fill(Theme.well)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.accentGradient).frame(width: geo.size.width * CGFloat(done) / CGFloat(steps.count))
                        }
                }
                .frame(height: 6)
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
            ForEach(steps.indices, id: \.self) { i in
                if i > 0 { RowDivider(inset: 52) }
                HStack(spacing: 14) {
                    ZStack {
                        if steps[i].done {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
                        } else {
                            Circle().strokeBorder(Theme.hairline, lineWidth: 1.5)
                            Text("\(i + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(steps[i].title).font(.system(size: 13.5, weight: .medium))
                        Text(steps[i].detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if !steps[i].done {
                        Button(steps[i].button, action: steps[i].action).buttonStyle(.pill(.primary))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .card(padding: 0)
    }

    private func mode(_ keys: [String], _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            KeyCombo(keys: keys, large: true).padding(.bottom, 10)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted()).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Verlauf

private struct HistoryPage: View {
    let navigation: Navigation
    @ObservedObject private var store = HistoryStore.shared
    @State private var query = ""

    private var days: [(title: String, entries: [HistoryEntry])] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty ? store.entries : store.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return Dictionary(grouping: matches) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
            .map { (Self.title(for: $0.key), $0.value) }
    }

    var body: some View {
        let days = self.days
        return PageScroll {
            PageHeader(title: L("Verlauf"),
                       subtitle: store.retentionDays == 0 ? L("Der Verlauf ist ausgeschaltet.")
                           : L("Einträge: %lld · Aufbewahrung: %@", store.entries.count, retentionLabel(store.retentionDays))) {
                if !store.entries.isEmpty { SearchField(text: $query) }
            }

            if store.retentionDays == 0, store.entries.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                        .background(Theme.well, in: Circle())
                    Text(L("Diktate werden nicht gespeichert.")).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.secondary)
                    Button(L("Einstellungen öffnen")) { navigation.page = .settings }.buttonStyle(.pill)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else if days.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: store.entries.isEmpty ? "waveform" : "magnifyingglass")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                        .background(Theme.well, in: Circle())
                    Text(store.entries.isEmpty ? L("Noch keine Diktate.") : L("Nichts gefunden."))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            }

            ForEach(days, id: \.title) { day in
                TitledGroup(title: day.title) {
                    VStack(spacing: 0) {
                        ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider(inset: 72) }
                            HistoryRow(entry: entry)
                        }
                    }
                    .card(padding: 0)
                }
            }
        }
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()

    private static func title(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return L("Heute") }
        if Calendar.current.isDateInYesterday(day) { return L("Gestern") }
        return dayFormat.string(from: day)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var hovering = false
    @State private var copied = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(Self.time.string(from: entry.date))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(entry.text)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Label(copied ? L("Kopiert") : L("Kopieren"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : .primary)
                    .frame(width: 28, height: 24)
                    .background(Theme.well, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(hovering || copied ? 1 : 0)
            .help(L("Kopieren"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 13)
        .background(Color.primary.opacity(hovering ? 0.025 : 0))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("Kopieren"), action: copy)
            Button(L("Löschen"), role: .destructive) { HistoryStore.shared.delete(entry) }
        }
    }

    private func copy() {
        TextInsertion.copy(entry.text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Wörterbuch

private struct DictionaryPage: View {
    @ObservedObject private var store = DictionaryStore.shared
    @State private var word = ""
    @State private var from = ""
    @State private var to = ""
    @State private var sample = ""

    var body: some View {
        PageScroll {
            PageHeader(title: L("Wörterbuch"), subtitle: L("Damit Namen und Begriffe immer richtig geschrieben werden."))

            TitledGroup(title: L("Deine Wörter")) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        InputField(placeholder: L("z. B. ein Name"), text: $word, onSubmit: addWord)
                        Button(L("Hinzufügen"), action: addWord)
                            .buttonStyle(.pill(.primary))
                            .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if store.woerter.isEmpty {
                        Text(L("Noch keine Wörter.")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(store.woerter, id: \.self) { entry in
                                Chip(text: entry) { store.woerter.removeAll { $0 == entry } }
                            }
                        }
                    }
                }
                .card(padding: 16)
                Footnote(L("Steno gibt sie Whisper als Hinweis und korrigiert ähnlich klingende Verhörer automatisch."))
            }

            TitledGroup(title: L("Feste Ersetzungen")) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        InputField(placeholder: L("Whisper schreibt …"), text: $from)
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        InputField(placeholder: L("… richtig ist"), text: $to, onSubmit: addReplacement)
                        Button(L("Hinzufügen"), action: addReplacement)
                            .buttonStyle(.pill(.primary))
                            .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(16)
                    ForEach(store.ersetzungen) { r in
                        RowDivider()
                        HStack(spacing: 10) {
                            Text(r.von).font(.system(size: 13.5))
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Text(r.zu).font(.system(size: 13.5, weight: .medium))
                            Spacer()
                            Button { store.ersetzungen.removeAll { $0.id == r.id } } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 24, height: 24)
                                    .background(Theme.well, in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(L("Entfernen"))
                            .accessibilityLabel(L("%@ entfernen", r.von))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                .card(padding: 0)
                Footnote(L("Werden immer exakt ersetzt – für Fälle, die der automatische Abgleich nicht erkennt."))
            }

            TitledGroup(title: L("Korrektur testen")) {
                VStack(alignment: .leading, spacing: 12) {
                    InputField(placeholder: L("z. B. „Termin mit Frau Meyr“ – einen Satz mit falsch geschriebenem Namen"), text: $sample)
                    if !sample.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green)
                            Text(TextCleanup.apply(sample, store.vocabulary, language: SpeechLanguage.current.whisperCode,
                                                  swiss: SpeechLanguage.current == .swissGerman))
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 13.5, weight: .medium))
                    }
                }
                .card(padding: 16)
                Footnote(L("Prüft deine Einträge ohne Diktieren: Darunter steht der Satz so, wie Steno ihn nach dem Diktat einfügen würde."))
            }
        }
    }

    private func addWord() {
        let entry = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty, !store.woerter.contains(entry) else { return }
        store.woerter.append(entry)
        word = ""
    }

    private func addReplacement() {
        let entry = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        store.ersetzungen.append(Replacement(von: entry, zu: to.trimmingCharacters(in: .whitespacesAndNewlines)))
        from = ""
        to = ""
    }
}

/// „1 Tag“, „7 Tage“, „30 Tage“ – ohne Pluralregeln im Code.
func retentionLabel(_ days: Int) -> String {
    switch days {
    case 0: return L("Nicht speichern")
    case 1: return L("1 Tag")
    case 30: return L("30 Tage")
    default: return L("7 Tage")
    }
}
