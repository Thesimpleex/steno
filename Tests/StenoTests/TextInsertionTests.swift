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
}
