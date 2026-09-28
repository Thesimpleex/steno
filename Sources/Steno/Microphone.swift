import AVFoundation
import CoreAudio
import IOKit

/// Nimmt auf und liefert, was Whisper braucht: 16 kHz, mono, Float32.
///
/// Das Gerät wird nur auf einer eigenen Queue geöffnet, gestartet und angehalten: Das dauert je nach Mikrofon
/// (Bluetooth, gerade aufgewacht) unterschiedlich lange und soll weder den Hauptthread noch die Anzeige aufhalten.
final class Microphone {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Pegel 0…1 für die Anzeige – kommt auf dem Audio-Thread.
    var onLevel: ((Float) -> Void)?
    /// Jeder neue Abschnitt, schon im Whisper-Format – kommt auf dem Audio-Thread.
    var onSamples: (([Float]) -> Void)?
    /// Aus: Die Aufnahme wird nicht gesammelt, weil sie stückweise über `onSamples` weiterläuft (Meetings).
    var accumulates = true
    /// Der erste Puffer ist da, das Mikrofon hört also wirklich zu – kommt auf dem Hauptthread.
    var onListening: (() -> Void)?
    /// Der Start im Hintergrund ist fehlgeschlagen – kommt auf dem Hauptthread.
    var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "steno.microphone", qos: .userInitiated)
    /// `input`: das Standard-Mikrofon beim Öffnen – wechselt es, taugt das vorbereitete Gerät nicht mehr.
    private typealias Prepared = (engine: AVAudioEngine, number: Int, input: AudioDeviceID?)
    // Nur auf `queue`: das laufende Gerät und eines, das vorbereitet auf seinen Start wartet.
    private var engine: AVAudioEngine?
    private var spare: Prepared?
    private var spareExpiry: DispatchWorkItem?
    private var built = 0

    private var capture = Capture()
    private let lock = NSLock()  // für `capture`

    enum Failure: Error { case noInput, notAllowed }

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Öffnet das Gerät schon, ohne aufzunehmen: Startet die Aufnahme gleich danach, geht es schneller.
    /// Bleibt es ungenutzt, wird es nach ein paar Sekunden wieder geschlossen.
    func prepare() {
        queue.async {
            if let prepared = try? self.prepared() { self.keep(prepared) }
        }
    }

    /// Für Diktate: startet auf der eigenen Queue. Ob es geklappt hat, melden `onListening` und `onFailure`.
    func startInBackground() {
        let id = lock.withLock { capture.request() }
        queue.async {
            do {
                try self.launch(self.prepared(), for: id)
            } catch {
                DispatchQueue.main.async {
                    if self.lock.withLock({ self.capture.isWanted(id) }) { self.onFailure?(error) }
                }
            }
        }
    }

    /// Startet sofort; wartet, bis das Gerät läuft.
    func start() throws {
        try queue.sync { try launch(takeSpare() ?? build(), for: nil) }
    }

    /// Was bisher aufgenommen wurde, ohne die Aufnahme zu beenden.
    func snapshot() -> [Float] {
        lock.withLock { capture.samples }
    }

    /// Beendet die Aufnahme und liefert, was bis hierher kam. Das Gerät hält danach im Hintergrund an.
    func stop() -> [Float] {
        let samples = lock.withLock { capture.end() }
        queue.async {
            self.engine?.inputNode.removeTap(onBus: 0)
            self.engine?.stop()
            self.engine = nil
        }
        return samples
    }

    /// Für Diktate: das vorbereitete Gerät, sonst ein neues – das nur mit Freigabe. Die Abfrage dauert jedes Mal
    /// einige Millisekunden, deshalb hier statt auf dem Hauptthread. Nur auf `queue`.
    private func prepared() throws -> Prepared {
        if let spare = takeSpare() { return spare }
        guard Self.authorized else { throw Failure.notAllowed }
        return try build()
    }

    /// `id`: die Aufnahme, für die gestartet wird. Ist sie inzwischen schon wieder beendet, bleibt das Gerät
    /// nur vorbereitet – so geht bei ⌥L & Co. kein Mikrofon an. Nur auf `queue`.
    private func launch(_ prepared: Prepared, for id: Int?) throws {
        guard lock.withLock({ capture.begin(id, engine: prepared.number) }) else { return keep(prepared) }
        try prepared.engine.start()
        engine = prepared.engine
    }

    /// Alles außer dem Start: Gerät wählen, Format, Umwandlung, Abgriff. Nur auf `queue`.
    private func build() throws -> Prepared {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let defaultInput = Self.defaultInput
        // Ist das Standard-Mikrofon ein Bluetooth-Headset (AirPods), das eingebaute nehmen: sonst fällt
        // der Kopfhörer beim Musikhören in den schlechten Headset-Modus. Sonst gilt die Systemeinstellung.
        // Bei zugeklapptem MacBook ist das eingebaute Mikrofon stumm – dann bleibt es beim Headset.
        if let defaultInput, Self.isBluetooth(defaultInput), !Self.lidClosed, var device = Self.builtInMicrophone(),
           let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw Failure.noInput
        }
        built += 1
        let number = built
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.receive(buffer, converter: converter, from: number)
        }
        engine.prepare()
        return (engine, number, defaultInput)
    }

    /// Hebt ein vorbereitetes Gerät kurz auf. Nur auf `queue`.
    private func keep(_ prepared: Prepared) {
        spare = prepared
        spareExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in self?.spare = nil }
        spareExpiry = expiry
        queue.asyncAfter(deadline: .now() + 5, execute: expiry)
    }

    /// Das vorbereitete Gerät – aber nur, solange dasselbe Mikrofon Standard ist. Nur auf `queue`.
    private func takeSpare() -> Prepared? {
        defer { spare = nil }
        return spare?.input == Self.defaultInput ? spare : nil
    }

    /// Auf dem Audio-Thread.
    private func receive(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, from number: Int) {
        let converted = Self.convert(buffer, with: converter)
        let keeping = accumulates
        guard let first = lock.withLock({ capture.receive(converted, from: number, keeping: keeping) }) else { return }
        if first {
            DispatchQueue.main.async {
                if self.lock.withLock({ self.capture.isLive(number) }) { self.onListening?() }
            }
        }
        onLevel?(Self.level(of: buffer))
        if let converted { onSamples?(converted) }
    }

    private static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
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

    /// Bringt einen Puffer in das Whisper-Format; auch die Quelle für den Mac-Ton nutzt das.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
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

    /// Das Standard-Mikrofon laut Systemeinstellungen.
    private static var defaultInput: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        return device
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
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

    /// Welche Puffer zur Aufnahme gehören. Hauptthread, Queue und Audio-Thread teilen sich das, immer unter `lock`.
    struct Capture {
        private(set) var samples: [Float] = []
        private var requested = 0
        private var wanted = 0  // die Aufnahme, die laufen soll; 0: keine
        private var live = 0    // das Gerät, dessen Puffer zählen; 0: keins
        private var heard = false

        /// Hauptthread: Eine neue Aufnahme soll starten.
        mutating func request() -> Int {
            requested += 1
            wanted = requested
            return requested
        }

        /// Queue: Gerät `engine` startet für Aufnahme `id` – ohne `id` in jedem Fall.
        /// false: Die Aufnahme ist inzwischen schon wieder beendet.
        mutating func begin(_ id: Int?, engine: Int) -> Bool {
            guard id == nil || id == wanted else { return false }
            live = engine
            heard = false
            samples.removeAll(keepingCapacity: true)
            return true
        }

        /// Audio-Thread: nil, wenn der Puffer nicht (mehr) dazugehört, sonst ob es der erste ist.
        mutating func receive(_ new: [Float]?, from engine: Int, keeping: Bool) -> Bool? {
            guard engine == live else { return nil }
            if keeping, let new { samples.append(contentsOf: new) }
            defer { heard = true }
            return !heard
        }

        /// Hauptthread: Aufnahme beenden und abgeben, was gesammelt wurde.
        mutating func end() -> [Float] {
            wanted = 0
            live = 0
            defer { samples = [] }
            return samples
        }

        func isWanted(_ id: Int) -> Bool { id == wanted }
        func isLive(_ engine: Int) -> Bool { engine == live }
    }
}
