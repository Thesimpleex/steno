import AVFoundation
import CoreAudio
import IOKit

/// Nimmt auf und liefert, was Whisper braucht: 16 kHz, mono, Float32.
///
/// Das Gerät wird nur auf einer eigenen Queue geöffnet, gestartet und angehalten: Das dauert je nach Mikrofon
/// (Bluetooth, gerade aufgewacht) unterschiedlich lange und soll weder den Hauptthread noch die Anzeige aufhalten.
///
/// Aufgenommen wird über eine Capture-Session genau von dem gewählten Gerät. AVAudioEngine öffnet dagegen immer
/// erst das Standard-Mikrofon – bei AirPods schaltet das den Kopfhörer schon in den Headset-Modus, und das
/// nachträgliche Umlenken auf ein anderes Gerät passt nicht mehr zum Format und bringt die App zum Absturz.
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
    private var session: AVCaptureSession?  // nur auf `queue`: das laufende Gerät
    private var tap: Tap?                   // nur auf `queue`: hält den Empfänger der Puffer am Leben
    private var opened = 0                  // nur auf `queue`

    private var capture = Capture()
    private let lock = NSLock()  // für `capture`

    enum Failure: Error { case noInput, notAllowed }

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Für Diktate: startet auf der eigenen Queue. Ob es geklappt hat, melden `onListening` und `onFailure`.
    func startInBackground() {
        let id = lock.withLock { capture.request() }
        queue.async {
            do {
                // Die Abfrage der Freigabe dauert jedes Mal einige Millisekunden, deshalb hier statt auf dem Hauptthread.
                guard Self.authorized else { throw Failure.notAllowed }
                try self.open(for: id)
            } catch {
                DispatchQueue.main.async {
                    if self.lock.withLock({ self.capture.isWanted(id) }) { self.onFailure?(error) }
                }
            }
        }
    }

    /// Startet sofort; wartet, bis das Gerät läuft.
    func start() throws {
        try queue.sync { try open(for: nil) }
    }

    /// Was bisher aufgenommen wurde, ohne die Aufnahme zu beenden.
    func snapshot() -> [Float] {
        lock.withLock { capture.samples }
    }

    /// Beendet die Aufnahme und liefert, was bis hierher kam. Das Gerät hält danach im Hintergrund an und wird freigegeben.
    func stop() -> [Float] {
        let samples = lock.withLock { capture.end() }
        queue.async { self.close() }
        return samples
    }

    /// Nur auf `queue`.
    private func close() {
        session?.stopRunning()
        session = nil
        tap = nil
    }

    /// Öffnet und startet das Gerät für Aufnahme `id`. Ist sie schon wieder beendet (⌥L & Co.), wird das Gerät
    /// gar nicht erst angefasst – sonst schaltet etwa ein Bluetooth-Kopfhörer um. Nur auf `queue`.
    private func open(for id: Int?) throws {
        opened += 1
        let number = opened
        guard lock.withLock({ capture.begin(id, engine: number) }) else { return }
        close()
        guard let device = Self.chosenDevice() else { throw Failure.noInput }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // Float32 getrennt nach Kanälen, Abtastrate und Kanalzahl bleiben wie beim Gerät; umgerechnet wird danach.
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                                AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false]
        let tap = Tap { [weak self] buffer, converter in self?.receive(buffer, converter: converter, from: number) }
        output.setSampleBufferDelegate(tap, queue: DispatchQueue(label: "steno.microphone.buffers", qos: .userInitiated))
        // Vorher fragen statt hinzufügen und hoffen: Ein unpassendes Gerät löst sonst eine Ausnahme aus.
        guard session.canAddInput(input), session.canAddOutput(output) else { throw Failure.noInput }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        guard session.isRunning else { throw Failure.noInput }
        self.session = session
        self.tap = tap
    }

    /// Welches Mikrofon: Ist das Standard-Mikrofon ein Bluetooth-Headset (AirPods), das eingebaute – sonst fällt
    /// der Kopfhörer beim Musikhören in den schlechten Headset-Modus. Bei zugeklapptem MacBook ist das eingebaute
    /// stumm, dann bleibt es beim Headset. Sonst gilt die Systemeinstellung.
    enum Choice: Equatable { case builtIn, systemDefault }

    static func choose(defaultIsBluetooth: Bool, lidClosed: Bool, builtInAvailable: Bool) -> Choice {
        defaultIsBluetooth && !lidClosed && builtInAvailable ? .builtIn : .systemDefault
    }

    /// Das Gerät zur Wahl. Nur Geräte, die hier herauskommen, werden überhaupt geöffnet.
    private static func chosenDevice() -> AVCaptureDevice? {
        let standard = defaultInput()
        let builtIn = builtInMicrophone()
        let isBluetooth = standard.map { [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transportType($0)) }
        switch choose(defaultIsBluetooth: isBluetooth ?? false, lidClosed: lidClosed, builtInAvailable: builtIn != nil) {
        case .builtIn:
            return builtIn.flatMap(uid).flatMap(AVCaptureDevice.init(uniqueID:))
        case .systemDefault:
            return standard.flatMap(uid).flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        }
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
        if let converted {
            onLevel?(Self.level(of: converted))
            onSamples?(converted)
        }
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

    /// Aus den schon umgerechneten Samples – so ist egal, in welchem Format das Gerät liefert.
    private static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
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

    private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Unter dieser Kennung kennt auch AVFoundation das Gerät.
    private static func uid(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
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

    /// Macht aus den Puffern der Session PCM-Puffer. Der Umrechner entsteht erst am tatsächlichen Format und wird
    /// neu gebaut, sobald es sich ändert – ein Formatwechsel mitten in der Aufnahme kann so nichts zum Absturz bringen.
    private final class Tap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        private let deliver: (AVAudioPCMBuffer, AVAudioConverter) -> Void
        private var converter: AVAudioConverter?  // nur auf der Queue der Puffer

        init(_ deliver: @escaping (AVAudioPCMBuffer, AVAudioConverter) -> Void) { self.deliver = deliver }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let description = sampleBuffer.formatDescription else { return }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard format.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)),
                  buffer.frameCapacity > 0 else { return }
            buffer.frameLength = buffer.frameCapacity
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength),
                                                               into: buffer.mutableAudioBufferList) == noErr else { return }
            if converter?.inputFormat != format { converter = AVAudioConverter(from: format, to: Microphone.format) }
            guard let converter else { return }
            deliver(buffer, converter)
        }
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
