import AppKit
import SwiftUI

/// Ein beendetes Meeting zum Nachlesen.
struct MeetingDetailView: View {
    let item: MeetingLibrary.Item
    let library: MeetingLibrary
    @ObservedObject var navigation: Navigation
    @State private var file: MeetingFile?
    @State private var unreadable = false
    @State private var copied = false
    @State private var confirmTrash = false

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                back
                PageHeader(title: item.info.title, subtitle: MeetingFormat.summary(of: item.info))
                actions
            }

            if let file {
                if file.entries.isEmpty {
                    note(L("Keine Einträge."))
                } else {
                    MeetingTimeline(entries: file.entries, othersLabel: file.info.othersLabel, folder: item.folder)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .card(padding: 0)
                }
            } else if unreadable {
                note(L("Dieses Meeting lässt sich nicht lesen."))
            }
        }
        .task(id: item.id) {
            file = library.file(of: item)
            unreadable = file == nil
        }
        .confirmationDialog(L("Dieses Meeting in den Papierkorb legen?"), isPresented: $confirmTrash) {
            Button(L("In den Papierkorb"), role: .destructive) {
                library.trash(item)
                navigation.meeting = nil
            }
        } message: {
            Text(L("Protokoll und Bilder liegen danach im Papierkorb."))
        }
    }

    private var back: some View {
        Button { navigation.meeting = nil } label: {
            Label(L("Meetings"), systemImage: "chevron.left")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: copyMarkdown) {
                Label(copied ? L("Kopiert") : L("Markdown kopieren"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.pill)
            .disabled(file == nil)
            Button(L("Im Finder zeigen")) { NSWorkspace.shared.open(item.folder) }
                .buttonStyle(.pill)
            Button(L("In den Papierkorb")) { confirmTrash = true }
                .buttonStyle(.pill(.destructive))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private func copyMarkdown() {
        guard let file else { return }
        TextInsertion.copy(MeetingStore.markdown(for: file))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
