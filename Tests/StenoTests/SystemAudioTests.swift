import AVFoundation
import XCTest
@testable import Steno

/// Was am Ton des Macs ohne echten Abgriff und ohne Freigabe prüfbar ist.
final class SystemAudioTests: XCTestCase {
    /// So liefert der Abgriff seine Blöcke: 48 kHz, Stereo, Float32, verschränkt.
    private let tapFormat: AVAudioFormat = {
        var stream = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        return AVAudioFormat(streamDescription: &stream)!
    }()

    private let separateChannels = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    func testConvertsTapBlocksToWhisperFormat() {
        for format in [tapFormat, separateChannels] {
            let samples = convert(format, seconds: 1) { _, time in 0.5 * sin(2 * .pi * 440 * time) }
            XCTAssertEqual(Double(samples.count), 16_000, accuracy: 100, "\(format)")
            XCTAssertEqual(rms(samples.dropFirst(1_000)), 0.5 / sqrt(2), accuracy: 0.02, "\(format)")
        }
    }

    func testKeepsWhatPlaysOnlyOnTheRight() {
        let samples = convert(tapFormat, seconds: 1) { channel, time in channel == 1 ? 0.5 * sin(2 * .pi * 440 * time) : 0 }
        XCTAssertGreaterThan(rms(samples.dropFirst(1_000)), 0.1)
    }

    func testSkipsBlocksThatDoNotMatchTheFormat() {
        let converter = SystemAudio.converter(for: separateChannels)!
        let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 480)!
        mono.frameLength = 480
        XCTAssertNil(SystemAudio.samples(from: mono.audioBufferList, format: separateChannels, converter: converter))
        let empty = AVAudioPCMBuffer(pcmFormat: separateChannels, frameCapacity: 480)!
        XCTAssertNil(SystemAudio.samples(from: empty.audioBufferList, format: separateChannels, converter: converter))
    }

    func testLevel() {
        XCTAssertEqual(SystemAudio.level(of: []), 0)
        XCTAssertEqual(SystemAudio.level(of: [Float](repeating: 0, count: 1_600)), 0)
        XCTAssertEqual(SystemAudio.level(of: [Float](repeating: 0.05, count: 1_600)), 0.6, accuracy: 0.001)
        XCTAssertEqual(SystemAudio.level(of: [Float](repeating: -1, count: 1_600)), 1, "nie über 1")
    }

    func testTeardownRunsBackwardsAndOnlyOnce() {
        let teardown = SystemAudio.Teardown()
        var steps: [String] = []
        teardown.add { steps.append("Abgriff") }
        teardown.add { steps.append("Sammelgerät") }
        teardown.add { steps.append("Callback") }
        teardown.run()
        teardown.run()
        XCTAssertEqual(steps, ["Callback", "Sammelgerät", "Abgriff"])
    }

    func testStoppingIsSafeTwiceAndFromAnyThread() {
        let audio = SystemAudio()
        audio.stopCapture()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in audio.stopCapture() }
        audio.stopCapture()
    }

    func testExcludesStenoAndMusicWithTheirHelpers() {
        let clients: [SystemAudio.Client] = [
            (1, 100, "com.microsoft.teams2"),
            (2, 200, "com.spotify.client"),
            (3, 201, "com.spotify.client.helper"),
            (4, 300, "com.apple.Music"),
            (5, 301, "com.apple.MusicRecognition"),
            (6, 400, ""),  // Steno selbst, als Programm ohne Bundle gestartet
            (7, 500, "com.google.Chrome.helper"),
        ]
        XCTAssertEqual(SystemAudio.excluded(clients, own: 400), [2, 3, 4, 6])
        XCTAssertEqual(SystemAudio.excluded([], own: 400), [])
    }

    // MARK: Hilfen

    /// Schickt ein Signal in Blöcken zu 10 ms durch die Wandlung, so wie der Callback sie bekommt.
    private func convert(_ format: AVAudioFormat, seconds: Int,
                         signal: (_ channel: Int, _ time: Float) -> Float) -> [Float] {
        let converter = SystemAudio.converter(for: format)!
        let frames = 480
        var output: [Float] = []
        for block in 0..<(100 * seconds) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<frames {
                    let time = Float(block * frames + frame) / 48_000
                    buffer.floatChannelData![channel][frame * buffer.stride] = signal(channel, time)
                }
            }
            output += SystemAudio.samples(from: buffer.audioBufferList, format: format, converter: converter) ?? []
        }
        return output
    }

    private func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}
