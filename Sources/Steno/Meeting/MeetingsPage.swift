import SwiftUI

struct MeetingsPage: View {
    @ObservedObject var meeting: MeetingSession
    @ObservedObject var library: MeetingLibrary

    var body: some View {
        PageScroll {
            PageHeader(title: L("Meetings"), subtitle: L("Gespräche mit Zeitstempel mitschreiben."))
        }
    }
}
