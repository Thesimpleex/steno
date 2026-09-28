import SwiftUI

struct SettingsPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelStore
    @ObservedObject private var history = HistoryStore.shared
    @State private var confirmClear = false
    @State private var confirmStopHistory = false
    @State private var meetingFolder = MeetingFolder.displayPath

    private static let project = URL(string: "https://github.com/Thesimpleex/steno")!
    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"

    var body: some View {
        PageScroll {
            PageHeader(title: L("Einstellungen"), subtitle: L("Alles bleibt auf diesem Mac."))

            TitledGroup(title: L("Sprache")) {
                Row(title: L("Diktiersprache"), detail: state.language.note) {
                    PillPicker(title: L("Diktiersprache"), selection: $state.language,
                               options: SpeechLanguage.allCases.map { ($0, "\($0.flag)  \($0.name)") })
                }
                .card(padding: 0)
            }

            TitledGroup(title: L("Taste")) {
                HotKeyPicker(selection: $state.hotKey)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .card(padding: 0)
                if let note = state.hotKey.note { Footnote(note) }
            }

            TitledGroup(title: L("Anzeige beim Diktieren")) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ForEach(OverlayStyle.allCases) { style in
                            OverlayTile(style: style, selected: state.overlayStyle == style) { state.overlayStyle = style }
                        }
                    }
                    HStack(spacing: 12) {
                        Text(state.overlayStyle.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button(L("Vorschau"), action: state.previewOverlay).buttonStyle(.pill)
                    }
                }
                .card(padding: 16)
            }

            TitledGroup(title: L("Sprachmodell")) {
                VStack(spacing: 0) {
                    ForEach(Array(ModelCatalog.all.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { RowDivider(inset: 48) }
                        modelRow(model)
                    }
                    RowDivider(inset: 48)
                    customModelRow
                }
                .card(padding: 0)
                Link(destination: ModelCatalog.browseURL) {
                    Label(L("Alle Whisper-Modelle auf Hugging Face ansehen"), systemImage: "arrow.up.right")
                        .foregroundStyle(Theme.accentText)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 4)
            }

            TitledGroup(title: L("Verhalten")) {
                VStack(spacing: 0) {
                    toggle(L("Text automatisch einfügen"), L("Aus: Der Text landet nur in der Zwischenablage."), $state.autoInsert)
                    RowDivider()
                    toggle(L("Töne beim Starten und Beenden"), nil, $state.sounds)
                    RowDivider()
                    toggle(L("Musik beim Diktieren pausieren"), L("Spotify und Apple Music"), $state.pauseMusic)
                    RowDivider()
                    toggle(L("Beim Anmelden öffnen"), nil, Binding(get: { state.autostart }, set: { state.setAutostart($0) }))
                }
                .card(padding: 0)
            }

            TitledGroup(title: L("Verlauf")) {
                VStack(spacing: 0) {
                    Row(title: L("Diktate aufbewahren")) {
                        PillPicker(title: L("Diktate aufbewahren"), selection: retention,
                                   options: [0, 1, 7, 30].map { ($0, retentionLabel($0)) })
                    }
                    RowDivider()
                    Row(title: L("Gespeichert: %lld", history.entries.count)) {
                        Button(L("Verlauf jetzt löschen"), role: .destructive) { confirmClear = true }
                            .buttonStyle(.pill(.destructive))
                            .disabled(history.entries.isEmpty)
                    }
                }
                .card(padding: 0)
            }

            TitledGroup(title: L("Meetings")) {
                Row(title: L("Speicherort"), detail: meetingFolder) {
                    Button(L("Ändern …")) {
                        if MeetingFolder.choose() { meetingFolder = MeetingFolder.displayPath }
                    }
                    .buttonStyle(.pill)
                    Button(L("Im Finder zeigen"), action: MeetingFolder.reveal).buttonStyle(.pill)
                }
                .card(padding: 0)
                Footnote(L("Jedes Meeting liegt in einem eigenen Ordner mit Protokoll und Bildern. Der Ton wird nie gespeichert."))
            }

            TitledGroup(title: L("Über Steno")) {
                Row(title: L("Version %@", Self.version), detail: L("Freie Software unter der MIT-Lizenz.")) {
                    Link(destination: Self.project) {
                        Label(L("Quellcode auf GitHub"), systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.pill)
                }
                .card(padding: 0)
            }
        }
        .confirmationDialog(L("Den ganzen Verlauf löschen?"), isPresented: $confirmClear) {
            Button(L("Löschen"), role: .destructive) { history.deleteAll() }
        } message: {
            Text(L("Das lässt sich nicht rückgängig machen."))
        }
        .confirmationDialog(L("Verlauf ausschalten?"), isPresented: $confirmStopHistory) {
            Button(L("Ausschalten und löschen"), role: .destructive) { history.retentionDays = 0 }
        } message: {
            Text(L("Die gespeicherten Diktate werden dabei gelöscht."))
        }
    }

    /// „Nicht speichern“ löscht den vorhandenen Verlauf – deshalb vorher nachfragen.
    private var retention: Binding<Int> {
        Binding(get: { history.retentionDays }, set: { days in
            if days == 0, !history.entries.isEmpty { confirmStopHistory = true } else { history.retentionDays = days }
        })
    }

    private func toggle(_ title: String, _ detail: String?, _ isOn: Binding<Bool>) -> some View {
        Row(title: title, detail: detail) {
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    // MARK: Modelle

    private func modelRow(_ model: WhisperModel) -> some View {
        let selected = models.active == model.file
        let installed = models.installed.contains(model.file)
        return HStack(spacing: 12) {
            radio(selected)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).font(.system(size: 13.5, weight: .medium))
                    if model == ModelCatalog.recommended {
                        Text(L("Empfohlen"))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(Theme.accentText)
                    }
                }
                Text("\(model.summary) · \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if case .failed(let failed, let reason) = models.download, failed == model {
                    Text(reason).font(.system(size: 11.5)).foregroundStyle(Theme.accentText).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            modelActions(model, selected: selected, installed: installed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func modelActions(_ model: WhisperModel, selected: Bool, installed: Bool) -> some View {
        switch models.download {
        case .loading(let m, let received) where m == model:
            ProgressView(value: Double(received), total: Double(model.bytes)).frame(width: 100)
            cancelButton
        case .checking(let m) where m == model:
            ProgressView().controlSize(.small)
            Text(L("Wird geprüft …")).font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed(let m, _) where m == model:
            Button(L("Erneut versuchen")) { models.retryNow() }.buttonStyle(.pill)
            cancelButton
        default:
            if installed {
                if selected {
                    Text(L("In Benutzung")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    Button(L("Benutzen")) { models.select(model) }.buttonStyle(.pill)
                    Button { models.delete(model) } label: { Image(systemName: "trash").font(.system(size: 11.5)) }
                        .buttonStyle(.pill)
                        .help(L("Löschen"))
                        .accessibilityLabel(L("Löschen"))
                }
            } else {
                Button(L("Laden und benutzen")) { models.select(model) }
                    .buttonStyle(.pill)
                    .disabled(models.isDownloading)
            }
        }
    }

    private var cancelButton: some View {
        Button { models.cancelDownload() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
            .buttonStyle(.pill)
            .help(L("Abbrechen"))
            .accessibilityLabel(L("Abbrechen"))
    }

    private var customModelRow: some View {
        let selected = models.active?.hasPrefix("/") == true
        return HStack(spacing: 12) {
            radio(selected)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Eigenes Modell")).font(.system(size: 13.5, weight: .medium))
                Text(models.customPath ?? L("Eine ggml-Datei von whisper.cpp, z. B. von Hugging Face."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let problem = models.problem {
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.accentText)
                }
            }
            Spacer(minLength: 12)
            Button(L("Datei wählen …")) { models.chooseCustomFile() }.buttonStyle(.pill)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func radio(_ selected: Bool) -> some View {
        ZStack {
            Circle().strokeBorder(selected ? Theme.accent : Color.secondary.opacity(0.45), lineWidth: 1.5)
            if selected { Circle().fill(Theme.accent).padding(4.5) }
        }
        .frame(width: 18, height: 18)
        .frame(width: 20)
    }
}

/// Auswahlkachel mit kleiner Bildschirm-Skizze.
private struct OverlayTile: View {
    let style: OverlayStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ScreenSketch(style: style)
                    .frame(height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2 : 1))
                Text(style.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .frame(maxWidth: .infinity)
    }
}

/// Angedeuteter Bildschirm: Menüleiste, Dock und die Anzeige an der Notch oder als Blase.
private struct ScreenSketch: View {
    let style: OverlayStyle

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.58, green: 0.70, blue: 0.88), Color(red: 0.95, green: 0.76, blue: 0.68)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                Rectangle().fill(.white.opacity(0.5)).frame(height: 7)
                Spacer()
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white.opacity(0.45)).frame(width: 64, height: 9)
                    .padding(.bottom, 4)
            }
            VStack(spacing: 0) {
                if style != .bubble {
                    pill(width: 50, height: 11, radius: 4)
                        .opacity(style == .automatic ? 0.9 : 1)
                }
                Spacer()
                if style != .notch {
                    pill(width: 38, height: 11, radius: 5.5)
                        .opacity(style == .automatic ? 0.45 : 1)
                        .padding(.bottom, 17)
                }
            }
        }
    }

    private func pill(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: style == .bubble || radius > 5 ? radius : 0,
                               bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                               topTrailingRadius: style == .bubble || radius > 5 ? radius : 0, style: .continuous)
            .fill(.black)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Circle().fill(Theme.accent).frame(width: 4, height: 4).padding(.leading, 6)
            }
    }
}
