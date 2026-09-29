import XCTest
@testable import Steno

final class ActiveScreenTests: XCTestCase {
    // Wie bei Alexander: Ultrawide als Hauptbildschirm, MacBook rechts daneben, etwas tiefer.
    private let screens = [CGRect(x: 0, y: 0, width: 3440, height: 1440), CGRect(x: 3440, y: -146, width: 1800, height: 1169)]

    func testWindowOnTheSecondScreen() {
        // Fenstersystem: Ursprung oben links am Hauptbildschirm, y wächst nach unten.
        XCTAssertEqual(NotchOverlay.screen(for: CGRect(x: 3600, y: 400, width: 900, height: 600), among: screens), 1)
    }

    func testWindowOnTheMainScreen() {
        XCTAssertEqual(NotchOverlay.screen(for: CGRect(x: 200, y: 100, width: 1200, height: 800), among: screens), 0)
    }

    func testWindowAcrossBothCountsWhereMostOfItIs() {
        XCTAssertEqual(NotchOverlay.screen(for: CGRect(x: 3000, y: 300, width: 1400, height: 600), among: screens), 1)
    }

    func testWindowOutsideAllScreens() {
        XCTAssertNil(NotchOverlay.screen(for: CGRect(x: -5000, y: 0, width: 100, height: 100), among: screens))
    }
}
