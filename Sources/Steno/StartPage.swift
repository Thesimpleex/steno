import AppKit
import SwiftUI

private extension String {
    var wordCount: Int { split(whereSeparator: \.isWhitespace).count }
}

struct StartPage: View {
    @ObservedObject var state: AppState
    let navigation: Navigation
    @ObservedObject var meeting: MeetingSession
    @ObservedObject var library: MeetingLibrary
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        PageScroll {
            hero
            if !state.ready { setup }

            meetingCard

            // Solange ein Meeting läuft, gehört die Meetings-Seite ihm; ältere lassen sich dort nicht öffnen.
            if meeting.state == .idle, !library.items.isEmpty { recentMeetings }

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
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            stat(history.entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.text.wordCount },
                                 L("Wörter heute"))
                            divider
                            stat(history.entries.reduce(0) { $0 + $1.text.wordCount }, L("Wörter im Verlauf"))
                            divider
                            stat(history.entries.count, L("Diktate im Verlauf"))
                        }
                        .padding(18)
                        ForEach(history.entries.prefix(3)) { entry in
                            RowDivider(inset: 0)
                            RecentDictation(entry: entry) { navigation.page = .history }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .card(padding: 0)
                }
            }

            tip
        }
        .onAppear { library.reload() }
    }

    private var key: String { state.hotKey.symbol }

    private var recentMeetings: some View {
        TitledGroup(title: L("Letzte Meetings")) {
            VStack(spacing: 0) {
                ForEach(Array(library.items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider() }
                    MeetingRow(info: item.info) {
                        navigation.meeting = item
                        navigation.page = .meetings
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .card(padding: 0)
        }
    }

    private var tip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 12))
            Text(L("Return während der Aufnahme schickt den Text nach dem Einfügen gleich ab. ⌘Q schließt nur das Fenster, ⌥⌘Q beendet Steno."))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    /// Startet gleich ein Meeting und wechselt auf dessen Seite – dort steht auch, falls der Start scheitert. Während
    /// eines Meetings zeigt die Karte stattdessen dessen Laufzeit.
    private var meetingCard: some View {
        Button {
            if meeting.state == .idle { meeting.start() }
            navigation.page = .meetings
        } label: {
            HStack(spacing: 14) {
                if meeting.state == .idle {
                    IconBadge(symbol: "person.2", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Meeting starten")).font(.system(size: 14, weight: .semibold))
                        Text(L("Mikrofon und Ton des Macs, mit Zeitstempel – alles bleibt auf diesem Mac."))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                } else {
                    RecordingDot(size: 10)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.info.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(meeting.state == .running ? L("Meeting läuft") : L("Das Ende des Gesprächs wird noch aufgeschrieben …"))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if meeting.state == .running { MeetingClock(since: meeting.info.startedAt) }
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
    }

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

/// Ein letztes Diktat in der Verlaufskarte: der Text, darunter wann es war.
private struct RecentDictation: View {
    let entry: HistoryEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text).font(.system(size: 13.5)).lineLimit(2).lineSpacing(2)
                Text(MeetingFormat.day(entry.date)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.025 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
