import AppKit
import SwiftUI

struct DictionaryPage: View {
    @ObservedObject private var store = DictionaryStore.shared
    @State private var word = ""
    @State private var from = ""
    @State private var to = ""
    @State private var sample = ""
    @State private var corrected = ""

    var body: some View {
        PageScroll {
            PageHeader(title: L("Wörterbuch"), subtitle: L("Damit Namen und Begriffe immer richtig geschrieben werden."))

            TitledGroup(title: L("Deine Wörter")) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        InputField(placeholder: L("z. B. ein Name"), text: $word, onSubmit: addWord)
                        Button(L("Hinzufügen"), action: addWord)
                            .buttonStyle(.pill(.primary))
                            .disabled(!canAddWord)
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
                            Text(corrected).textSelection(.enabled)
                        }
                        .font(.system(size: 13.5, weight: .medium))
                    }
                }
                .card(padding: 16)
                .onChange(of: sample, initial: true) { correctSample() }
                .onChange(of: store.woerter) { correctSample() }
                .onChange(of: store.ersetzungen.map { [$0.von, $0.zu] }) { correctSample() }
                Footnote(L("Prüft deine Einträge ohne Diktieren: Darunter steht der Satz so, wie Steno ihn nach dem Diktat einfügen würde."))
            }
        }
    }

    /// Ein Wort, das schon in der Liste steht, lässt sich nicht noch einmal hinzufügen – der Knopf zeigt das gleich.
    private var canAddWord: Bool {
        let entry = word.trimmingCharacters(in: .whitespacesAndNewlines)
        return !entry.isEmpty && !store.woerter.contains(entry)
    }

    /// Auf der Queue der Nachbearbeitung: Die Rechtschreibprüfung verträgt keine gleichzeitigen Aufrufe, etwa während
    /// ein Meeting läuft, und wäre bei jedem Neuzeichnen auf dem Main-Thread zu langsam.
    private func correctSample() {
        let text = sample, vocabulary = store.vocabulary
        let language = SpeechLanguage.current
        TextCleanup.queue.async {
            let result = TextCleanup.apply(text, vocabulary, language: language.whisperCode, swiss: language == .swissGerman)
            DispatchQueue.main.async {
                if sample == text { corrected = result }  // ein späterer Satz ist schon unterwegs
            }
        }
    }

    private func addWord() {
        let entry = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAddWord else { return }
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
