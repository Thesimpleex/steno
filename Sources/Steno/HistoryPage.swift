import AppKit
import SwiftUI

struct HistoryPage: View {
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

/// „1 Tag“, „7 Tage“, „30 Tage“ – ohne Pluralregeln im Code.
func retentionLabel(_ days: Int) -> String {
    switch days {
    case 0: return L("Nicht speichern")
    case 1: return L("1 Tag")
    case 30: return L("30 Tage")
    default: return L("7 Tage")
    }
}
