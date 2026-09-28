import AVFoundation
import CoreAudio
import IOKit

/// Nimmt auf und liefert, was Whisper braucht: 16 kHz, mono, Float32.
final class Microphone {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Pegel 0…1 für die Anzeige – kommt auf dem Audio-Thread.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()

    enum Failure: Error { case noInput }

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Ist das Standard-Mikrofon ein Bluetooth-Headset (AirPods), das eingebaute nehmen: sonst fällt
        // der Kopfhörer beim Musikhören in den schlechten Headset-Modus. Sonst gilt die Systemeinstellung.
        // Bei zugeklapptem MacBook ist das eingebaute Mikrofon stumm – dann bleibt es beim Headset.
        if Self.defaultInputIsBluetooth, !Self.lidClosed, var device = Self.builtInMicrophone(), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw Failure.noInput
        }

        lock.withLock { samples.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.onLevel?(Self.level(of: buffer))
            if let converted = Self.convert(buffer, with: converter) {
                self.lock.withLock { self.samples.append(contentsOf: converted) }
            }
        }
        try engine.start()
        self.engine = engine
    }

    /// Was bisher aufgenommen wurde, ohne die Aufnahme zu beenden.
    func snapshot() -> [Float] {
        lock.withLock { samples }
    }

    private static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }

    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        return lock.withLock {
            defer { samples.removeAll() }
            return samples
        }
    }

    /// Audiodatei ins Whisper-Format bringen (für `Steno --test`).
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return [] }
        try file.read(into: buffer)
        return convert(buffer, with: converter) ?? []
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let frames = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        let rms = sqrt(frames.reduce(0) { $0 + $1 * $1 } / Float(frames.count))
        return min(1, rms * 12)
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    private static var defaultInputIsBluetooth: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        let type = transportType(device)
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type)
        return type
    }

    private static func builtInMicrophone() -> AudioDeviceID? {
        func hasInput(_ device: AudioDeviceID) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
        }

        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }

        return devices.first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }
}
