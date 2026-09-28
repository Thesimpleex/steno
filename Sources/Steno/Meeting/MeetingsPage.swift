import AppKit
import SwiftUI

extension Settings {
    /// Was beim nächsten Meeting aufgenommen wird; beim ersten Mal beides.
    static var meetingSources: MeetingSources {
        get {
            (UserDefaults.standard.object(forKey: "meetingQuellen") as? Int).map(MeetingSources.init(rawValue:))
                ?? [.microphone, .systemAudio]
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "meetingQuellen") }
    }
}

extension MeetingSession {
    /// Datum und Uhrzeit stehen ohnehin im Ordnernamen und in der Liste.
    static var defaultTitle: String { L("Meeting") }

    /// So starten Meetings-Seite und Startseite: mit den gemerkten Quellen, ohne Titel als „Meeting“.
    func start(title: String = "", done: @escaping (Error?) -> Void = { _ in }) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        start(title: name.isEmpty ? Self.defaultTitle : name, sources: Settings.meetingSources, done: done)
    }
}

/// Die Ablage der Meetings anzeigen, wechseln und im Finder öffnen – für die Meetings-Seite und die Einstellungen.
enum MeetingFolder {
    static var displayPath: String { (MeetingStore.root.path as NSString).abbreviatingWithTildeInPath }

    /// Fragt nach einem anderen Ordner; true, wenn er gewechselt wurde.
    static func choose() -> Bool {
        let panel = NSOpenPanel()
        panel.message = L("Hier legt Steno die Meetings ab.")
        panel.prompt = L("Wählen")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = MeetingStore.root
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        Settings.meetingFolder = url.path
        return true
    }

    /// Vor dem ersten Meeting gibt es den Ordner noch nicht – dann wird er angelegt, damit das Finder-Fenster aufgeht.
    static func reveal() {
        try? FileManager.default.createDirectory(at: MeetingStore.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingStore.root)
    }
}

struct MeetingsPage: View {
    @ObservedObject var navigation: Navigation
    @ObservedObject var meeting: MeetingSession
    @ObservedObject var library: MeetingLibrary
    @State private var title = ""
    @State private var sources = Settings.meetingSources

    var body: some View {
        Group {
            switch meeting.state {
            case .idle:
                if let item = navigation.meeting {
                    MeetingDetailView(item: item, library: library, navigation: navigation)
                } else {
                    idle
                }
            case .running, .finishing:
                MeetingRunningView(meeting: meeting)
            }
        }
        .onAppear { library.reload() }
        .onChange(of: meeting.state) { _, state in
            if state == .idle { library.reload() }
        }
    }

    private var idle: some View {
        PageScroll {
            PageHeader(title: L("Meetings"), subtitle: L("Gespräche mit Zeitstempel mitschreiben."))
            startCard
            MeetingList(library: library, navigation: navigation)
        }
    }

    // MARK: Starten

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            InputField(placeholder: MeetingSession.defaultTitle, text: $title, onSubmit: start)
                .accessibilityLabel(L("Titel"))
            HStack(spacing: 24) {
                sourceSwitch(L("Mikrofon"), help: L("Deine Stimme"), source: .microphone)
                sourceSwitch(L("Mac-Ton"), help: L("Was der Mac abspielt: Teams, Zoom, der Browser …"), source: .systemAudio)
            }
            HStack(alignment: .center, spacing: 16) {
                Text(L("Nimm nur auf, wenn alle Beteiligten zustimmen (§ 201 StGB)."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(action: start) {
                    // Der Start dauert beim ersten Mal ein paar Sekunden; so sieht man, dass etwas passiert.
                    if meeting.isStarting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Startet …"))
                        }
                    } else {
                        Text(L("Meeting starten"))
                    }
                }
                .buttonStyle(.pill(.primary, large: true))
                .disabled(meeting.isStarting)
            }
            if let failure = meeting.startError { MeetingBanner(text: failure) }
        }
        .card()
    }

    private func sourceSwitch(_ name: String, help: String, source: MeetingSources) -> some View {
        let isOn = Binding(get: { sources.contains(source) }, set: { on in
            if on { sources.insert(source) } else { sources.remove(source) }
            Settings.meetingSources = sources
            meeting.startError = nil
        })
        return HStack(spacing: 8) {
            Text(name).font(.system(size: 13.5))
            Toggle(name, isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .help(help)
    }

    private func start() {
        meeting.start(title: title) { error in
            if error == nil { title = "" }
        }
    }
}

/// Die früheren Meetings mit Suche und der Zeile zur Ablage. Eigene Ansicht, damit Tippen im Titelfeld nicht jedes Mal
/// die Suche in der Ablage neu anstößt.
private struct MeetingList: View {
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var navigation: Navigation
    @State private var query = ""
    @State private var folder = MeetingFolder.displayPath

    var body: some View {
        let items = library.items(matching: query)
        VStack(alignment: .leading, spacing: 10) {
            if library.items.isEmpty {
                placeholder("person.2", L("Noch keine Meetings."))
            } else {
                HStack(spacing: 12) {
                    SectionTitle(L("Frühere Meetings"))
                    Spacer(minLength: 12)
                    SearchField(text: $query)
                }
                if items.isEmpty {
                    placeholder("magnifyingglass", L("Nichts gefunden."))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { RowDivider() }
                            MeetingRow(info: item.info) { navigation.meeting = item }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .card(padding: 0)
                }
            }
            folderLine
        }
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Theme.well, in: Circle())
            Text(text).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var folderLine: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 12)).accessibilityHidden(true)
            Text(folder).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Button(L("Ändern …")) {
                if MeetingFolder.choose() {
                    folder = MeetingFolder.displayPath
                    library.reload()
                }
            }
            .foregroundStyle(Theme.accentText)
            Button(L("Im Finder zeigen"), action: MeetingFolder.reveal)
                .foregroundStyle(Theme.accentText)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}
