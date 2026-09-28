import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Ein Whisper-Modell aus dem offiziellen whisper.cpp-Repository auf Hugging Face.
struct WhisperModel: Identifiable, Equatable {
    let file: String
    let name: String
    let summary: String
    let bytes: Int64
    let sha256: String  // laut Hugging Face (LFS-Objekt) zur festen Revision unten

    var id: String { file }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(ModelCatalog.revision)/\(file)")! }
    var localURL: URL { Paths.models.appendingPathComponent(file) }
}

enum ModelCatalog {
    /// Feste Revision, zu der die Prüfsummen gehören – ein späterer Austausch auf „main“ ändert nichts.
    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let all = [
        WhisperModel(file: "ggml-large-v3-turbo.bin", name: "Large v3 Turbo", summary: L("Sehr genau und schnell"),
                     bytes: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        WhisperModel(file: "ggml-large-v3-turbo-q5_0.bin", name: L("Large v3 Turbo (kompakt)"),
                     summary: L("Fast genauso gut, ein Drittel so groß"),
                     bytes: 574_041_195, sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        WhisperModel(file: "ggml-large-v3.bin", name: "Large v3", summary: L("Am genauesten, aber langsamer"),
                     bytes: 3_095_033_483, sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
        WhisperModel(file: "ggml-small.bin", name: "Small", summary: L("Klein und schnell, dafür ungenauer"),
                     bytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        WhisperModel(file: "ggml-base.bin", name: "Base", summary: L("Sehr klein – eher zum Testen"),
                     bytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
    ]
    static let recommended = all[0]
    static let compact = all[1]
    static let browseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/main")!

    static func model(_ file: String) -> WhisperModel? { all.first { $0.file == file } }
}

/// Welche Modelle da sind, welches läuft, und das Laden neuer Modelle.
///
/// `selection` (gespeichert) ändert sich erst, wenn ein Modell wirklich geladen werden konnte.
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum Download: Equatable {
        case idle
        case loading(WhisperModel, received: Int64)
        case checking(WhisperModel)
        case failed(WhisperModel, String)
    }

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var download = Download.idle
    /// Dateiname eines Katalog-Modells oder voller Pfad eines eigenen Modells – so, wie der Nutzer es gewählt hat.
    @Published private(set) var selection: String
    /// Was gerade tatsächlich läuft (kann vorübergehend vom gewählten abweichen).
    @Published private(set) var active: String?
    @Published private(set) var problem: String?

    /// Lädt die Datei in Whisper und meldet, ob es geklappt hat.
    var load: ((URL, @escaping (Bool) -> Void) -> Void)?

    private var session: URLSession?
    private var pending: String?  // wird nach dem Download benutzt
    private var activating = false
    private var resumedTask = false  // lief der aktuelle Download aus Fortsetzungsdaten?
    private var resumeData: [String: Data] = [:]
    private var attempts = 0
    private var retry: DispatchWorkItem?

    override init() {
        selection = Settings.model ?? ModelCatalog.recommended.file
        super.init()
        removeLeftovers()
        refresh()
    }

    #if DEBUG
    /// Für die Vorschaubilder: so tun, als liefe dieses Modell – ohne Download.
    func pretendActive(_ file: String) {
        installed = [file]
        active = file
    }
    #endif

    var hasAnyModel: Bool { !installed.isEmpty || customPath.map { FileManager.default.fileExists(atPath: $0) } == true }
    var customPath: String? { selection.hasPrefix("/") ? selection : nil }

    func name(of id: String) -> String {
        id.hasPrefix("/") ? URL(fileURLWithPath: id).lastPathComponent : ModelCatalog.model(id)?.name ?? id
    }

    /// Beim Start (oder im Assistenten): gewähltes Modell laden; fehlt es, ein vorhandenes – sonst herunterladen.
    func prepare() {
        guard active == nil, pending == nil, !activating else { return }
        if let path = customPath {
            if FileManager.default.fileExists(atPath: path) { return activate(URL(fileURLWithPath: path), id: path, remember: true) }
            problem = L("Eigenes Modell nicht gefunden: %@", URL(fileURLWithPath: path).lastPathComponent)
        } else if installed.contains(selection), let model = ModelCatalog.model(selection) {
            return activate(model.localURL, id: model.file, remember: true)
        }
        if let fallback = ModelCatalog.all.first(where: { installed.contains($0.file) }) {
            activate(fallback.localURL, id: fallback.file, remember: false)  // Wahl bleibt gespeichert
        } else if customPath == nil {
            start(ModelCatalog.model(selection) ?? ModelCatalog.recommended)
        }
    }

    func select(_ model: WhisperModel) {
        retry?.cancel()
        if installed.contains(model.file) {
            pending = nil  // ein laufender Download installiert nur noch, ohne die Wahl zu überschreiben
            activate(model.localURL, id: model.file, remember: true)
        } else {
            start(model)
        }
    }

    func chooseCustomFile() {
        let panel = NSOpenPanel()
        panel.title = L("Eigenes Whisper-Modell wählen")
        panel.message = L("Eine ggml-Datei von whisper.cpp, z. B. von Hugging Face.")
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pending = nil
        activate(url, id: url.path, remember: true)
    }

    func delete(_ model: WhisperModel) {
        guard active != model.file, !isBusy(with: model) else { return }
        try? FileManager.default.removeItem(at: model.localURL)
        refresh()
    }

    func cancelDownload() {
        retry?.cancel()
        session?.invalidateAndCancel()
        session = nil
        pending = nil
        resumeData.removeAll()
        download = .idle
    }

    func retryNow() {
        guard case .failed(let model, _) = download else { return }
        attempts = 0
        start(model)
    }

    func isBusy(with model: WhisperModel) -> Bool {
        switch download {
        case .loading(let m, _), .checking(let m): return m == model
        default: return false
        }
    }

    var isDownloading: Bool {
        switch download {
        case .loading, .checking: return true
        default: return false
        }
    }

    private func activate(_ url: URL, id: String, remember: Bool) {
        activating = true
        load?(url) { [weak self] ok in
            guard let self else { return }
            self.activating = false
            if ok {
                self.active = id
                if remember {
                    self.problem = nil
                    self.selection = id
                    Settings.model = id
                }
            } else {
                self.problem = L("Diese Modelldatei lässt sich nicht laden.")
            }
        }
    }

    private func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? []
        installed = Set(files.filter { ModelCatalog.model($0) != nil })
    }

    /// Reste abgebrochener Downloads aufräumen.
    private func removeLeftovers() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? []
        for file in files where file.hasSuffix(".teil") {
            try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(file))
        }
    }

    // MARK: Download

    private func start(_ model: WhisperModel) {
        retry?.cancel()
        session?.invalidateAndCancel()
        if pending != model.file { attempts = 0 }
        pending = model.file
        let free = (try? Paths.models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free > model.bytes + 500_000_000 else {
            download = .failed(model, L("Nicht genug Speicherplatz frei (%@ nötig).",
                                        ByteCountFormatter.string(fromByteCount: model.bytes + 500_000_000, countStyle: .file)))
            return
        }
        download = .loading(model, received: 0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        if let data = resumeData.removeValue(forKey: model.file) {
            resumedTask = true
            session.downloadTask(withResumeData: data).resume()
        } else {
            resumedTask = false
            session.downloadTask(with: model.url).resume()
        }
    }

    private var current: WhisperModel? {
        switch download {
        case .loading(let m, _), .checking(let m), .failed(let m, _): return m
        case .idle: return nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard case .loading(let model, let received) = download,
              totalBytesWritten - received > 4_000_000 || totalBytesWritten == model.bytes else { return }
        download = .loading(model, received: totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = current else { return }
        guard (downloadTask.response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true else {
            if resumedTask { return start(model) }  // Fortsetzen ging schief – einmal frisch beginnen
            download = .failed(model, L("Der Server hat die Datei nicht geliefert."))
            return
        }
        // Die temporäre Datei verschwindet, sobald diese Methode endet – also sofort umziehen.
        let staging = Paths.models.appendingPathComponent(model.file + ".teil")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            download = .failed(model, error.localizedDescription)
            return
        }
        download = .checking(model)
        DispatchQueue.global(qos: .utility).async {
            let size = (try? FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? Int64) ?? 0
            let intact = size == model.bytes && Self.sha256(of: staging) == model.sha256
            DispatchQueue.main.async {
                guard intact, (try? FileManager.default.moveItem(at: staging, to: model.localURL)) != nil else {
                    try? FileManager.default.removeItem(at: staging)
                    self.download = .failed(model, size == model.bytes
                        ? L("Die Prüfsumme stimmt nicht – bitte Steno aktualisieren.")
                        : L("Die Datei ist unvollständig angekommen."))
                    return
                }
                self.download = .idle
                self.refresh()
                if self.pending == model.file {
                    self.pending = nil
                    self.activate(model.localURL, id: model.file, remember: true)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if self.session === session { self.session = nil }
        guard let error = error as? URLError, error.code != .cancelled, let model = current else { return }
        if resumedTask, error.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
            resumedTask = false
            return start(model)  // Fortsetzen ging schief – einmal frisch beginnen
        }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[model.file] = data }
        download = .failed(model, error.localizedDescription)

        // Nur bei Netzproblemen neu versuchen (z. B. beim Autostart ohne WLAN) – höchstens dreimal.
        let network: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
        let delays: [Double] = [30, 120, 600]
        guard network.contains(error.code), attempts < delays.count else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .failed(let failed, _) = self.download, failed == model, self.pending == model.file else { return }
            self.start(model)
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempts], execute: work)
        attempts += 1
    }

    private static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
