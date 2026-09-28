import Foundation

/// Eine Tonquelle für Meetings. Sie liefert, was Whisper braucht: 16 kHz, mono, Float32.
protocol AudioSource: AnyObject {
    /// Neue Samples, aufgerufen auf einem Audio-Thread.
    var onSamples: (([Float]) -> Void)? { get set }
    /// Pegel 0…1 für die Anzeige, ebenfalls auf einem Audio-Thread.
    var onLevel: ((Float) -> Void)? { get set }
    /// Wahr, solange die Quelle läuft, das System sie aber (noch) nichts hören lässt. Von jedem Thread lesbar.
    var lacksPermission: Bool { get }
    func start() throws
    func stopCapture()
}

extension AudioSource {
    var lacksPermission: Bool { false }
}

extension Microphone: AudioSource {
    func stopCapture() { _ = stop() }
}
