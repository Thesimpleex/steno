import XCTest
@testable import Steno

final class ChunkerTests: XCTestCase {
    func testSilenceGivesNothing() {
        var chunker = Chunker(offset: 0)
        XCTAssertEqual(chunker.append(TestAudio.silence(30)), [])
        XCTAssertNil(chunker.flush())
    }

    func testClosesAtPauseOnceEnoughWasSaid() throws {
        var chunker = Chunker(offset: 0)
        let chunks = chunker.append(TestAudio.silence(1) + TestAudio.speech(6) + TestAudio.silence(1) + TestAudio.speech(2))
        XCTAssertEqual(chunks.count, 1, "nach der letzten Silbe kam noch keine Pause")
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunk.offset, 1 - 0.48, accuracy: 0.05, "ein kurzes Stück Stille vor dem ersten Wort")
        XCTAssertEqual(chunk.duration, 0.48 + 6 + 0.72, accuracy: 0.1)
    }

    func testShortPauseKeepsGoingUntilEnoughWasSaid() throws {
        var chunker = Chunker(offset: 0)
        XCTAssertEqual(chunker.append(TestAudio.speech(1.5) + TestAudio.silence(1)), [])
        let chunks = chunker.append(TestAudio.speech(4) + TestAudio.silence(1))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(try XCTUnwrap(chunks.first).duration, 1.5 + 1 + 4 + 0.72, accuracy: 0.1)
    }

    func testLongPauseClosesEvenAShortReply() throws {
        var chunker = Chunker(offset: 0)
        let chunks = chunker.append(TestAudio.silence(1) + TestAudio.speech(0.5) + TestAudio.silence(3))
        XCTAssertEqual(chunks.count, 1)
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunk.offset, 1 - 0.48, accuracy: 0.05)
        XCTAssertEqual(chunk.duration, 0.48 + 0.5 + 2, accuracy: 0.1)
    }

    func testClickIsNoSpeech() {
        var chunker = Chunker(offset: 0)
        XCTAssertEqual(chunker.append(TestAudio.silence(1) + TestAudio.speech(0.03) + TestAudio.silence(3)), [])
        XCTAssertNil(chunker.flush())
    }

    func testFollowsTheNoiseFloor() throws {
        // Lautes Summen wie von einem Lüfter: Mit fester Schwelle wäre es Sprache, und nie käme eine Pause.
        var chunker = Chunker(offset: 0)
        let chunks = chunker.append(TestAudio.silence(2, hum: 0.03) + TestAudio.speech(6, loudness: 0.3, hum: 0.03)
                                    + TestAudio.silence(1, hum: 0.03))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(try XCTUnwrap(chunks.first).offset, 2 - 0.48, accuracy: 0.05)
    }

    func testMonologueIsCutBeforeTwentySecondsInAGap() {
        var chunker = Chunker(offset: 0)
        var chunks = chunker.append(TestAudio.speech(45))
        XCTAssertEqual(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.duration, 20)
            XCTAssertGreaterThan(chunk.duration, 10)
            XCTAssertLessThan(chunk.samples.suffix(480).map(abs).max()!, 0.01, "geschnitten wird in einer Lücke")
        }
        chunks += [chunker.flush()].compactMap { $0 }
        XCTAssertEqual(chunks.map(\.samples.count).reduce(0, +), 45 * 16_000, "nichts geht verloren")
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(b.offset, a.offset + a.duration, accuracy: 0.0001)
        }
    }

    func testFlushReturnsWhatIsLeft() throws {
        var chunker = Chunker(offset: 0)
        XCTAssertEqual(chunker.append(TestAudio.silence(0.5) + TestAudio.speech(2)), [])
        let tail = try XCTUnwrap(chunker.flush())
        XCTAssertEqual(tail.offset, 0, accuracy: 0.05)
        XCTAssertEqual(tail.duration, 2.5, accuracy: 0.05)
        XCTAssertNil(chunker.flush())
    }

    func testOffsetsCountFromTheStartOfTheMeeting() throws {
        var chunker = Chunker(offset: 100)
        let chunks = chunker.append(TestAudio.silence(10) + TestAudio.speech(6) + TestAudio.silence(1))
        XCTAssertEqual(try XCTUnwrap(chunks.first).offset, 110 - 0.48, accuracy: 0.05)
        XCTAssertEqual(chunker.position, 117, accuracy: 0.0001)
    }

    func testBufferSizeDoesNotMatter() {
        let audio = TestAudio.silence(1) + TestAudio.speech(6) + TestAudio.silence(1) + TestAudio.speech(3)
        var whole = Chunker(offset: 0)
        let expected = whole.append(audio) + [whole.flush()].compactMap { $0 }
        XCTAssertEqual(expected.count, 2)

        var pieces = Chunker(offset: 0)
        var chunks: [Chunker.Chunk] = []
        var index = 0
        var size = 1
        while index < audio.count {
            let end = min(audio.count, index + size)
            chunks += pieces.append(Array(audio[index..<end]))
            index = end
            size = size * 7 % 997 + 1
        }
        chunks += [pieces.flush()].compactMap { $0 }
        XCTAssertEqual(chunks, expected)
    }
}
