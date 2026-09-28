import AppKit
import AVFoundation
import CoreAudio

/// Der Ton des Macs (Teams, Zoom, Browser …) als Tonquelle für Meetings.
///
/// Ein Core-Audio-Abgriff mischt alles, was der Mac abspielt, zu Stereo – außer Steno selbst, Spotify und Apple Music.
/// Dafür braucht es keine Bildschirmaufnahme, nur die Freigabe für den Ton. Der Abgriff steckt in einem privaten
/// Sammelgerät, dessen Callback die Blöcke ins Whisper-Format bringt.
final class SystemAudio: AudioSource {
    var onSamples: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?

    /// Ein Prozess, der gerade mit Core Audio verbunden ist.
    typealias Client = (id: AudioObjectID, pid: pid_t, bundleID: String)

    /// Musik gehört nicht ins Protokoll.
    private static let musicPlayers = ["com.spotify.client", "com.apple.Music"]
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let batchSize = 1_600  // 0,1 s – so oft liefert auch das Mikrofon
    private static let ioQueue = DispatchSpecificKey<Void>()

    private let control = DispatchQueue(label: "steno.systemaudio")
    private let io = DispatchQueue(label: "steno.systemaudio.io", qos: .userInitiated)
    private let workspace = NSWorkspace.shared.notificationCenter
    // Nur auf `control` benutzt:
    private var active = false
    private let observers = Teardown()  // Wechsel des Ausgabegeräts, Aufwachen
    private let capture = Teardown()    // Abgriff, Sammelgerät, Callback
    private var rebuild: DispatchWorkItem?

    init() {
        io.setSpecific(key: Self.ioQueue, value: ())
    }

    deinit {
        // Nur falls stopCapture() fehlte. Nicht direkt abbauen: Der letzte Verweis kann im Callback enden,
        // und das Anhalten würde dann auf eben diesen Callback warten.
        control.async { [observers, capture] in
            observers.run()
            capture.run()
        }
    }

    /// Beim ersten Mal fragt macOS nach der Freigabe; bis zur Antwort kehrt `start()` nicht zurück.
    func start() throws {
        try control.sync {
            guard !active else { return }
            try build()
            active = true
            observe()
        }
    }

    /// Hält an und baut alles ab – beliebig oft und von jedem Thread aus.
    func stopCapture() {
        // Aus dem Callback heraus würde das Anhalten auf das Ende eben dieses Callbacks warten.
        if DispatchQueue.getSpecific(key: Self.ioQueue) != nil { return control.async(execute: stop) }
        control.sync(execute: stop)
    }

    private func stop() {
        active = false
        rebuild?.cancel()
        observers.run()
        capture.run()
    }

    /// Legt Abgriff, Sammelgerät und Callback an und startet sie. Scheitert ein Schritt, wird der Rest wieder abgebaut.
    private func build() throws {
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.excluded(Self.clients(), own: getpid()))
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tap = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateProcessTap(description, &tap))
            capture.add { AudioHardwareDestroyProcessTap(tap) }

            // Nur der Abgriff, ohne das Ausgabegerät: Hat es auch ein Mikrofon (USB-Headset, Monitor),
            // käme das sonst mit in den Callback.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Steno",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device))
            capture.add { AudioHardwareDestroyAggregateDevice(device) }

            var stream = try Self.read(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &stream), let converter = Self.converter(for: format) else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioDeviceUnsupportedFormatError))
            }
            var batch: [Float] = []
            var proc: AudioDeviceIOProcID?
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, io) { [weak self] _, input, _, _, _ in
                guard let self, let samples = Self.samples(from: input, format: format, converter: converter) else { return }
                batch += samples
                guard batch.count >= Self.batchSize else { return }
                self.onLevel?(Self.level(of: batch))
                self.onSamples?(batch)
                batch.removeAll(keepingCapacity: true)
            })
            capture.add { AudioDeviceDestroyIOProcID(device, proc!) }
            try Self.check(AudioDeviceStart(device, proc))
            capture.add { AudioDeviceStop(device, proc) }

            // Ohne Freigabe liefert der Abgriff Stille statt eines Fehlers. Seine Beschreibung neu zu setzen,
            // lehnt Core Audio dann aber ab – die einzige öffentliche Auskunft über die Freigabe.
            if Self.apply(description, to: tap) == kAudioDevicePermissionsError { throw MeetingError.systemAudioDenied }

            // AirPods wechseln beim Telefonieren ihr Format, ohne dass sich das Ausgabegerät ändert.
            if let output = try? Self.read(Self.system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown)) {
                capture.add(Self.listen(output, kAudioDevicePropertyNominalSampleRate, on: control) { [weak self] in
                    self?.scheduleRebuild()
                })
            }
        } catch {
            capture.run()
            throw error
        }
    }

    /// Neu aufbauen, wenn das Ausgabegerät wechselt (AirPods) oder der Mac aufwacht.
    private func observe() {
        observers.add(Self.listen(Self.system, kAudioHardwarePropertyDefaultOutputDevice, on: control) { [weak self] in
            self?.scheduleRebuild()
        })
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.control.async { self?.scheduleRebuild() }
        }
        observers.add { [workspace] in workspace.removeObserver(wake) }
    }

    /// Gerätewechsel kommen in Schüben: erst neu aufbauen, wenn es eine Sekunde ruhig war.
    /// Klappt der Aufbau nicht, versucht es der nächste Wechsel noch einmal.
    private func scheduleRebuild() {
        rebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.capture.run()
            try? self.build()
        }
        rebuild = work
        control.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: Ohne Core Audio prüfbar

    /// Was der Abgriff auslässt: Steno selbst und die Musik-Apps samt ihrer Hilfsprozesse.
    static func excluded(_ clients: [Client], own: pid_t) -> [AudioObjectID] {
        clients.filter { client in
            client.pid == own || musicPlayers.contains { client.bundleID == $0 || client.bundleID.hasPrefix($0 + ".") }
        }.map(\.id)
    }

    /// Vom Format des Abgriffs (meist 48 kHz Stereo) ins Whisper-Format.
    static func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: format, to: Microphone.format)
        // Beide Kanäle mischen – von sich aus nimmt der Wandler nur den linken, und FaceTime & Co. setzen Stimmen
        // auch nach rechts.
        converter?.downmix = true
        return converter
    }

    /// Ein Block aus dem Callback im Whisper-Format; nil, wenn er nicht zum Format passt.
    static func samples(from list: UnsafePointer<AudioBufferList>, format: AVAudioFormat, converter: AVAudioConverter) -> [Float]? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return nil }
        return Microphone.convert(buffer, with: converter)
    }

    /// Pegel 0…1, gerechnet wie beim Mikrofon.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        return min(1, rms * 12)
    }

    /// Baut in umgekehrter Reihenfolge ab, was aufgebaut wurde – auch nach einem halben Aufbau.
    /// Ein zweites `run()` tut nichts.
    final class Teardown {
        private var steps: [() -> Void] = []

        func add(_ step: @escaping () -> Void) { steps.append(step) }

        func run() {
            while let step = steps.popLast() { step() }
        }
    }

    // MARK: Core Audio

    private static func clients() -> [Client] {
        var address = global(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).map { id in
            let bundleID = (try? read(id, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none))?.takeRetainedValue()
            return (id, (try? read(id, kAudioProcessPropertyPID, pid_t(-1))) ?? -1, bundleID as String? ?? "")
        }
    }

    /// Liest eine Eigenschaft fester Größe; `value` gibt den Typ vor.
    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) throws -> T {
        var address = global(selector)
        var value = value
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
        return value
    }

    /// Setzt die Beschreibung eines bestehenden Abgriffs neu.
    private static func apply(_ description: CATapDescription, to tap: AudioObjectID) -> OSStatus {
        var address = global(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(description)
        return AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: reference)), &reference)
    }

    /// Meldet Änderungen einer Eigenschaft auf `queue`; der Rückgabewert meldet wieder ab.
    private static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, on queue: DispatchQueue,
                               _ action: @escaping () -> Void) -> () -> Void {
        var address = global(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return {} }
        return { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
    }

    private static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Fehlt die Freigabe, der Hinweis darauf; sonst der Fehler von Core Audio.
    private static func check(_ status: OSStatus) throws {
        if status == kAudioDevicePermissionsError { throw MeetingError.systemAudioDenied }
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
