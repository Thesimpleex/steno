import AppKit
import SwiftUI

private extension String {
    var wordCount: Int { split(whereSeparator: \.isWhitespace).count }
}

struct StartPage: View {
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
