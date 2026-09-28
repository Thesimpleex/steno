import Foundation

/// Baut Protokoll.md aus dem Inhalt von meeting.json.
enum MeetingMarkdown {
    /// Beiträge derselben Person, die höchstens 5 s nach dem vorigen beginnen, stehen in einem Absatz: Die Schnitte der Aufnahme sind technisch.
    private static let paragraphGap: TimeInterval = 5

    /// Sprache und Zeitzone lassen sich nur für Tests austauschen.
    static func render(_ file: MeetingFile, locale: Locale = .autoupdatingCurrent,
                       timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let info = file.info
        let entries = file.entries.enumerated()
            .sorted { ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset) }
            .map(\.element)

        let title = oneLine(info.title)
        var blocks = ["# " + (title.isEmpty ? L("Meeting") : title)]

        // Mit Wochentag: Eine Zeile, die mit „28.“ beginnt, wäre in Markdown eine nummerierte Liste.
        // Die Dauer trägt ein Wort, sonst läse sich „21:02“ neben dem Datum wie eine Uhrzeit.
        let date = info.startedAt.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: locale, timeZone: timeZone))
        blocks.append([date, oneLine(L("Dauer"), timestamp(info.duration)), oneLine(info.participants)]
            .filter { !$0.isEmpty }.joined(separator: " · "))

        let tasks = entries.compactMap { entry -> String? in
            guard case .task(let text) = entry.kind else { return nil }
            return oneLine("- [ ]", timestamp(entry.offset), text)
        }
        if !tasks.isEmpty { blocks += ["## " + L("Aufgaben"), tasks.joined(separator: "\n")] }

        blocks.append("## " + L("Mitschrift"))
        blocks += timeline(entries, othersLabel: info.othersLabel)
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// „12:40“, ab einer Stunde „1:05:30“. Unsinnige Werte aus einer von Hand bearbeiteten Datei ergeben „0:00“ statt eines Absturzes.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(exactly: seconds.rounded(.down)) ?? 0)
        let (hours, minutes, rest) = (total / 3600, (total / 60) % 60, total % 60)
        return hours > 0 ? String(format: "%lld:%02lld:%02lld", hours, minutes, rest) : String(format: "%lld:%02lld", minutes, rest)
    }

    /// Eine Zeile pro Eintrag; Aufgaben stehen nur oben, nicht noch einmal in der Mitschrift.
    private static func timeline(_ entries: [MeetingEntry], othersLabel: String) -> [String] {
        var lines: [String] = []
        var pending: (start: TimeInterval, last: TimeInterval, speaker: Speaker, texts: [String])?

        func close() {
            guard let paragraph = pending else { return }
            let name = paragraph.speaker == .you ? L("Du") : othersLabel
            lines.append(oneLine("**\(timestamp(paragraph.start)) \(name):**", paragraph.texts.joined(separator: " ")))
            pending = nil
        }

        for entry in entries {
            let time = timestamp(entry.offset)
            switch entry.kind {
            case .speech(let speaker, let text):
                if let current = pending, current.speaker == speaker, entry.offset - current.last <= paragraphGap {
                    pending?.last = entry.offset
                    pending?.texts.append(text)
                } else {
                    close()
                    pending = (entry.offset, entry.offset, speaker, [text])
                }
            case .note(let text):
                close()
                lines.append(oneLine("**\(time) \(L("Notiz")):**", text))
            case .mark:
                close()
                lines.append("**\(time) \(L("Markierung"))**")
            case .image(let name):
                close()
                lines.append("![\(L("Bild")) \(time)](\(MeetingFile.imageFolder)/\(name))")
            case .task:
                break
            }
        }
        close()
        return lines
    }

    /// Teile mit einfachen Leerzeichen verbinden: Ein Zeilenumbruch im Text könnte in Markdown eine Überschrift oder Liste beginnen.
    private static func oneLine(_ parts: String...) -> String {
        parts.flatMap { $0.split(whereSeparator: \.isWhitespace) }.joined(separator: " ")
    }
}
