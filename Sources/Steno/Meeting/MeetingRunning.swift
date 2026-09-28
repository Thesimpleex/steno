import SwiftUI

/// Die Laufzeit eines Meetings, jede Sekunde neu.
struct MeetingClock: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(clockText(context.date.timeIntervalSince(since))).font(.system(size: 13, weight: .medium).monospacedDigit())
        }
    }
}

/// Die Seite, solange ein Meeting läuft: Zeitleiste, Notizfeld, Pegel und „Beenden“.
struct MeetingRunningView: View {
    @ObservedObject var meeting: MeetingSession
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    private var running: Bool { meeting.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            InputField(placeholder: L("Teilnehmer"),
                       text: Binding(get: { meeting.info.participants }, set: meeting.setParticipants))
                .disabled(!running)
            if let problem = meeting.problem { banner(problem) }
            timeline
            if running {
                VStack(alignment: .leading, spacing: 8) {
                    InputField(placeholder: L("Notiz hinzufügen …"), text: $note, focus: $noteFocused, onSubmit: submit)
                    // Zeilengrenze statt `fixedSize`: Diese Seite liegt in keinem Scrollbereich, und ein Text, der bei Breite 0
                    // dutzende Zeilen bräuchte, triebe sonst die Mindesthöhe des Fensters hoch.
                    Text(L("Return speichert die Notiz. „!“ am Anfang macht eine Aufgabe, ein leeres Return setzt eine Markierung."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 4)
                }
            }
        }
        .padding(EdgeInsets(top: 30, leading: 32, bottom: 24, trailing: 32))
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { noteFocused = running }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.info.title).font(.system(size: 26, weight: .bold)).tracking(-0.3).lineLimit(1)
                status
            }
            Spacer(minLength: 16)
            if running { Button(L("Beenden"), action: meeting.stop).buttonStyle(.pill(.primary, large: true)) }
        }
    }

    @ViewBuilder private var status: some View {
        if running {
            HStack(spacing: 16) {
                HStack(spacing: 7) {
                    RecordingDot()
                    MeetingClock(since: meeting.info.startedAt)
                }
                if meeting.info.sources.contains(.microphone) {
                    HStack(spacing: 8) {
                        Text(L("Du")).speakerChip(.you)
                        LevelMeter(level: meeting.levels.you)
                    }
                }
                if meeting.info.sources.contains(.systemAudio) {
                    HStack(spacing: 8) {
                        OthersName(meeting: meeting, submitted: { noteFocused = true })
                        LevelMeter(level: meeting.levels.others)
                    }
                }
            }
            .frame(height: 20)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Das Ende des Gesprächs wird noch aufgeschrieben …")).font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
            .frame(height: 20)
        }
    }

    private var timeline: some View {
        FollowingScroll {
            MeetingTimeline(entries: meeting.entries, othersLabel: meeting.info.othersLabel, folder: meeting.folder,
                            remove: { meeting.remove($0) })
                .equatable()
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .overlay {
            if meeting.entries.isEmpty {
                Text(L("Sobald jemand spricht, erscheint der Text hier.")).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .card(padding: 0)
        .frame(minHeight: 160, maxHeight: .infinity)
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11.5))
            Text(text).font(.system(size: 12.5, weight: .medium)).lineLimit(3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.accentText)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func submit() {
        meeting.addNote(note)
        note = ""
    }
}

/// Der Name der Anderen im Kopf: sieht aus wie ihre Kapsel in der Zeitleiste, ein Klick macht ihn bearbeitbar.
private struct OthersName: View {
    @ObservedObject var meeting: MeetingSession
    /// Nach Return: der Cursor soll zurück ins Notizfeld.
    let submitted: () -> Void
    @State private var editing = false
    @FocusState private var focused: Bool

    /// Gemessen statt „so breit wie der Text“: Ein Textfeld richtet seine Breite nicht nach dem Inhalt, und ein langer
    /// Name soll die Kopfzeile nicht sprengen.
    private var width: CGFloat { min(speakerNameWidth(meeting.info.othersLabel) + 4, 200) }

    var body: some View {
        Group {
            if editing {
                TextField(L("Andere"), text: Binding(get: { meeting.info.othersName }, set: meeting.rename(others:)))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        editing = false
                        submitted()
                    }
                    .onAppear { focused = true }
                    .onChange(of: focused) { if !focused { editing = false } }
                    .frame(width: max(width, 70))
            } else {
                Button { editing = true } label: {
                    HStack(spacing: 5) {
                        Text(meeting.info.othersLabel).frame(width: width, alignment: .leading)
                        Image(systemName: "pencil").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(L("So heißen die anderen im Protokoll"))
            }
        }
        .speakerChip(.others)
    }
}

/// Kleine Pegelanzeige: ein Balken, der mit der Lautstärke wächst.
private struct LevelMeter: View {
    let level: Float
    private static let width: CGFloat = 48

    var body: some View {
        Capsule().fill(Theme.well)
            .frame(width: Self.width, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.ink).frame(width: Self.width * CGFloat(min(1, max(0, level))))
            }
            .animation(.easeOut(duration: 0.1), value: level)
            .accessibilityHidden(true)
    }
}
