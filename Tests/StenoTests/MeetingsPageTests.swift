import XCTest
@testable import Steno

final class MeetingsPageTests: XCTestCase {
    func testSummaryLeavesOutWhatIsMissing() {
        var info = MeetingInfo(title: "Test", startedAt: Date(timeIntervalSince1970: 0), sources: [])
        let day = MeetingFormat.day(info.startedAt)
        XCTAssertEqual(MeetingFormat.summary(of: info), day)
        info.participants = "Anna"
        XCTAssertEqual(MeetingFormat.summary(of: info), day + " · Anna")
        info.duration = 30
        XCTAssertEqual(MeetingFormat.summary(of: info), day + " · Anna", "unter einer Minute steht keine Dauer da")
        info.duration = 47 * 60
        XCTAssertTrue(MeetingFormat.summary(of: info).contains("47"))
    }

    func testSourcesAreRememberedAndDefaultToBoth() {
        UserDefaults.standard.removeObject(forKey: "meetingQuellen")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "meetingQuellen") }
        XCTAssertEqual(Settings.meetingSources, [.microphone, .systemAudio])
        Settings.meetingSources = [.microphone]
        XCTAssertEqual(Settings.meetingSources, [.microphone])
        Settings.meetingSources = []
        XCTAssertEqual(Settings.meetingSources, [], "auch „nichts“ wird gemerkt; das Meeting meldet dann selbst, dass eine Quelle fehlt")
    }
}
