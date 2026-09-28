import AppKit
import XCTest
@testable import Steno

final class TextInsertionTests: XCTestCase {
    /// Die Antworten kommen in der Reihenfolge der Fragen – so landen Diktate in ihrer Reihenfolge.
    func testAnswersKeepTheirOrder() {
        var order: [Int] = []
        let done = expectation(description: "alle Antworten")
        for i in 0..<20 {
            TextInsertion.inspect(probe: false) { target in
                XCTAssertFalse(target.canType, "ohne Nachfrage wird nichts eingefügt")
                order.append(i)
                if i == 19 { done.fulfill() }
            }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(order, Array(0..<20))
    }

    /// Zwischen Nachsehen und Einfügen kann eine andere App nach vorn kommen – dann geht nichts dorthin.
    func testPastesOnlyWhereItLooked() throws {
        let (looked, other) = try twoOtherApps()
        let target = TextInsertion.Target(canType: true, app: looked)
        XCTAssertTrue(target.isCurrent(frontmost: looked, ownField: false))
        XCTAssertFalse(target.isCurrent(frontmost: other, ownField: false))
        XCTAssertFalse(target.isCurrent(frontmost: looked, ownField: true), "inzwischen hat das Notizfeld die Tastatur")
        XCTAssertFalse(TextInsertion.Target().isCurrent(frontmost: looked, ownField: false), "nichts gefunden")
    }

    /// Das Notizfeld hat die Tastatur, auch wenn macOS Steno nicht nach vorn gelassen hat.
    func testOwnFieldCountsWithoutStenoInFront() throws {
        let (front, _) = try twoOtherApps()
        let target = TextInsertion.Target(canType: true, characterBefore: "", app: .current)
        XCTAssertTrue(target.isCurrent(frontmost: front, ownField: true))
        XCTAssertFalse(target.isCurrent(frontmost: .current, ownField: false), "das Feld ist schon zu")
    }

    private func twoOtherApps() throws -> (NSRunningApplication, NSRunningApplication) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0 != .current }
        guard apps.count >= 2 else { throw XCTSkip("braucht zwei laufende Apps") }
        return (apps[0], apps[1])
    }
}
