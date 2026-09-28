import SwiftUI

/// Wie Zeitpunkte und Meetings in Listen und Überschriften stehen: „Heute, 14:30 · 47 Min. · Anna Schmidt“.
enum MeetingFormat {
    private static let dayAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let length: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    /// „Heute, 14:30“, „Gestern, 14:30“, sonst mit Datum.
    static func day(_ date: Date) -> String { dayAndTime.string(from: date) }

    static func summary(of info: MeetingInfo) -> String {
        // Unter einer Minute würde „0 Min.“ dastehen – dann lieber gar keine Dauer.
        [day(info.startedAt), info.duration >= 60 ? length.string(from: info.duration) ?? "" : "", info.participants]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Zeile für ein Meeting: Titel, darunter Datum, Dauer und Teilnehmer.
struct MeetingRow: View {
    let info: MeetingInfo
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    Text(MeetingFormat.summary(of: info)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
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
