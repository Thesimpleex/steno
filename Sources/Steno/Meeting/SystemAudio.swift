import Foundation

/// Der Ton des Macs (Teams, Zoom, Browser …) als Tonquelle für Meetings.
final class SystemAudio: AudioSource {
    var onSamples: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?

    func start() throws { throw MeetingError.systemAudioDenied }

    func stopCapture() {}
}
