import AppKit
import Combine
import CryptoKit

// Serialize native rendering/encoding even when a cancelled job is winding down.
private actor LockScreenPreparationQueue {
    private var tail: Task<Void, Never>?
    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task { await previous?.value; try await operation() }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}

struct LockScreenDisplay {
    var id: String
    var name: String
    var size: CGSize
}

/// Owns the system Aerial slot; all mutations run on one queue, independently of encoding.
// Published state is confined to the main queue; file access is confined to io.
final class LockScreenSyncService: ObservableObject, @unchecked Sendable {
    static let shared = LockScreenSyncService()
    static let automaticDisplay = "automatic-main-display"
    @Published private(set) var activeDisplayName = ""
    @Published private(set) var enabled: Bool
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未啟用"
    @Published var sourceScreenID: String {
        didSet { defaults.set(sourceScreenID, forKey: "LockScreenSourceDisplay"); synchronize() }
    }
    @Published private(set) var protectsAerial: Bool
    // After restoring the complete system configuration, this session's cached
    // NSWorkspace still images must not overwrite it during app termination.
    private var restoredThisSession = false
    var suspendsDesktopOverrides: Bool { protectsAerial || restoredThisSession }
    let store: LockScreenStore
    private let defaults: UserDefaults
    private let reloadOverride: ((Bool) -> Void)?
    private let displays: () -> [LockScreenDisplay]
    private let mainDisplay: () -> String
    private let movieCache: URL
    @Published private(set) var activityTitle = ""
    @Published private(set) var activityStage = ""
    @Published private(set) var recordingProgress: Double?
    private var activityToken: LockScreenCancellation?
    @Published private(set) var preparationStatus = ""
    private let preparationQueue = LockScreenPreparationQueue()
    private var downloads: [WEWallpaper] = []
    private var warming: LockScreenCancellation?
    private var displayTransition = false
    private var selectedDisplay: LockScreenDisplay? {
        let id = sourceScreenID == Self.automaticDisplay ? mainDisplay() : sourceScreenID
        return displays().first { $0.id == id }
    }
    private var model: WallpaperViewModel?
    private var subscriptions = Set<AnyCancellable>()
    private let io = DispatchQueue(label: "com.openwallpaper.lock-screen-files", qos: .utility)
    private var cancellation = LockScreenCancellation()
    private var revision = 0
    private var lastSource: String?
    private var locked = false
    private var pending: (URL, Int, LockScreenCancellation)?
    private var observers: [NSObjectProtocol] = []

    init(store suppliedStore: LockScreenStore? = nil, defaults: UserDefaults = .standard, reload: ((Bool) -> Void)? = nil,
         displays: @escaping () -> [LockScreenDisplay] = {
             NSScreen.screens.map { LockScreenDisplay(id: WallpaperViewModel.screenId(for: $0), name: $0.localizedName, size: $0.frame.size) }
         }, mainDisplay: @escaping () -> String = { WallpaperViewModel.mainScreenId() }, movieCache: URL? = nil) {
        self.defaults = defaults; self.reloadOverride = reload
        self.displays = displays; self.mainDisplay = mainDisplay
        self.movieCache = movieCache ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Open Wallpaper Engine/LockScreenMovies")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = suppliedStore ?? LockScreenStore(root: support.appendingPathComponent("Open Wallpaper Engine/LockScreenSync"),
            videos: support.appendingPathComponent("com.apple.wallpaper/aerials/videos"),
            settings: support.appendingPathComponent("com.apple.wallpaper/Store/Index.plist"))
        let wasEnabled = defaults.bool(forKey: "LockScreenSyncEnabled")
        enabled = wasEnabled
        sourceScreenID = defaults.string(forKey: "LockScreenSourceDisplay") ?? Self.automaticDisplay
        let manifest = try? store.manifest()
        protectsAerial = wasEnabled || manifest?.installedHash != nil || manifest?.pendingHash != nil
    }
    func start(model: WallpaperViewModel) {
        guard self.model == nil else { return }
        self.model = model
        if sourceScreenID.isEmpty { sourceScreenID = Self.automaticDisplay }
        model.$wallpapers.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.synchronize() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: Notification.Name("WorkshopDownloadCompleted"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let directory = notification.object as? URL,
                      let data = try? Data(contentsOf: directory.appendingPathComponent("project.json")),
                      let project = try? JSONDecoder().decode(WEProject.self, from: data) else { return }
                self?.prepareDownloadedWallpaper(WEWallpaper(using: project, where: directory))
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: ScenePropertyStore.didChange)
            .debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let display = self.selectedDisplay, let wallpaper = self.model?.wallpapers[display.id],
                      wallpaper.project.type.lowercased() == "scene",
                      notification.object as? String == wallpaper.wallpaperDirectory.standardizedFileURL.path else { return }
                self.retry()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] _ in
                guard let self, self.enabled else { return }
                self.displayTransition = true; self.invalidate(); self.lastSource = nil
                self.busy = false; self.status = "等待螢幕設定穩定…保留目前鎖定影片"
            })
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.displayTransition = false; self?.synchronize() }.store(in: &subscriptions)
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = true })
        observers.append(center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.locked = false
            if let (url, revision, token) = self.pending { self.pending = nil; self.install(url, revision: revision, token: token) }
            self.warmNextDownload()
        })
        synchronize()
    }
    func setEnabled(_ value: Bool) {
        if value {
            guard #available(macOS 26.0, *) else { status = "此實驗功能需要 macOS 26 或更新版本"; return }
            enabled = true; protectsAerial = true
            defaults.set(true, forKey: "LockScreenSyncEnabled")
            retry()
        } else { restore() }
    }
    func retry() { lastSource = nil; synchronize() }
    private func invalidate() {
        clearActivity()
        warming?.cancel()
        revision += 1; cancellation.cancel(); cancellation = LockScreenCancellation()
        if let (url, _, _) = pending { try? FileManager.default.removeItem(at: url) }; pending = nil
    }
    private func synchronize() {
        guard enabled, !displayTransition, let model else { return }
        guard let display = selectedDisplay else {
            invalidate(); lastSource = nil; busy = false; activeDisplayName = ""
            status = "等待螢幕連接；保留目前鎖定影片"
            return
        }
        activeDisplayName = display.name
        guard let wallpaper = model.wallpapers[display.id], ["video", "scene"].contains(wallpaper.project.type.lowercased()) else {
            invalidate(); lastSource = nil; busy = false
            status = "此螢幕目前不是影片或場景桌布；保留上次的鎖定背景"
            warmNextDownload()
            return
        }
        let targetSize = display.size
        let source = wallpaper.wallpaperDirectory.appendingPathComponent(wallpaper.project.file)
        let values = try? source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let identity = "\(String(format: "%.6f", targetSize.width / max(1, targetSize.height)))|\(source.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        guard identity != lastSource else { return }
        lastSource = identity; invalidate()
        let generation = revision, token = cancellation
        beginActivity(wallpaper, token: token, download: false)
        busy = true; status = "正在檢查影片快取；需要時才會錄製或轉檔…"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("owe-aerial-\(UUID().uuidString).mov")
        Task.detached(priority: .utility) { [weak self] in
            do {
                guard let self else { return }
                try self.io.sync { try token.check(); _ = try self.store.prepare() }
                try await self.preparationQueue.run {
                    try token.check()
                    try await self.prepareMovie(wallpaper, targetSize: targetSize, output: output, token: token)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == generation, self.enabled else { try? FileManager.default.removeItem(at: output); return }
                    if self.locked { self.pending = (output, generation, token); self.status = "影片已準備好，解鎖後套用"; self.activityStage = self.status; self.recordingProgress = nil }
                    else { self.install(output, revision: generation, token: token) }
                }
            } catch {
                try? FileManager.default.removeItem(at: output)
                DispatchQueue.main.async { [weak self] in self?.finish(error: error, revision: generation) }
            }
        }
    }
    // Download preparation only populates caches. It never backs up, installs or reloads Aerial.
    func prepareDownloadedWallpaper(_ wallpaper: WEWallpaper) {
        guard enabled, ["scene", "video"].contains(wallpaper.project.type.lowercased()) else { return }
        if !downloads.contains(where: { $0.wallpaperDirectory == wallpaper.wallpaperDirectory }) {
            downloads.append(wallpaper)
        }
        warmNextDownload()
    }
    private func warmNextDownload() {
        guard enabled, !busy, !locked, !displayTransition, warming == nil,
              let display = selectedDisplay, let wallpaper = downloads.first else { return }
        let token = LockScreenCancellation()
        warming = token
        beginActivity(wallpaper, token: token, download: true)
        preparationStatus = "正在準備下載桌布的鎖定影片（待處理：\(downloads.count)）"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("owe-prewarm-\(UUID().uuidString).mov")
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var failure: Error?
            do {
                try await self.preparationQueue.run {
                    try token.check()
                    try await self.prepareMovie(wallpaper, targetSize: display.size, output: output, token: token)
                }
            } catch { failure = error }
            try? FileManager.default.removeItem(at: output)
            let result = failure
            DispatchQueue.main.async {
                self.warming = nil
                if self.activityToken === token { self.clearActivity() }
                if !(result is CancellationError) {
                    self.downloads.removeAll { $0.wallpaperDirectory == wallpaper.wallpaperDirectory }
                    self.preparationStatus = result.map { "下載桌布預備失敗：\($0.localizedDescription)；選用時會重試" } ?? "下載桌布的鎖定影片已準備好"
                }
                self.warmNextDownload()
            }
        }
    }
    private func beginActivity(_ wallpaper: WEWallpaper, token: LockScreenCancellation, download: Bool) {
        activityToken = token
        activityTitle = (download ? "預備鎖定影片：" : "同步鎖定影片：") + wallpaper.project.title
        activityStage = "等待處理／檢查快取…"
        recordingProgress = nil
    }
    private func clearActivity() {
        activityToken = nil; activityTitle = ""; activityStage = ""; recordingProgress = nil
    }
    private func reportActivity(_ stage: String, progress: Double? = nil, token: LockScreenCancellation) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enabled, self.activityToken === token,
                  (try? token.check()) != nil else { return }
            self.activityStage = stage
            self.recordingProgress = progress.map { min(1, max(0, $0)) }
        }
    }
    private func prepareMovie(_ wallpaper: WEWallpaper, targetSize: CGSize, output: URL,
                              token: LockScreenCancellation) async throws {
        let source = wallpaper.wallpaperDirectory.appendingPathComponent(wallpaper.project.file)
        let input = wallpaper.project.type.lowercased() == "scene" ? try await LockScreenSceneRecorder.record(wallpaper: wallpaper, targetSize: targetSize, cancellation: token, progress: { [weak self] value in
            self?.reportActivity("正在錄製場景（15 秒片段）", progress: value, token: token)
        }) : source
        try token.check()
        reportActivity("正在檢查影片快取", token: token)
        // The rendered scene cache is keyed by wallpaper/settings/aspect. A
        // second cache keeps the Aerial-ready movie so reuse skips HEVC too.
        let key = try LockScreenStore.hash(input) + "-aerial-v1"
        let cached = movieCache.appendingPathComponent(key + ".mov")
        let checksum = movieCache.appendingPathComponent(key + ".sha256")
        try FileManager.default.createDirectory(at: movieCache, withIntermediateDirectories: true)
        let expected = try? String(contentsOf: checksum, encoding: .utf8)
        let actual = expected == nil ? nil : try? LockScreenStore.hash(cached)
        if let expected, actual == expected {
            try FileManager.default.copyItem(at: cached, to: output)
        } else {
            reportActivity("正在轉換鎖定影片，請稍候…", token: token)
            try await LockScreenVideoEncoder.encode(source: input, output: output, cancellation: token)
            try token.check()
            // Serialized writes prevent a cancelled predecessor racing the
            // latest request. Only verified, complete movies are reusable.
            try io.sync {
                try token.check()
                let staging = movieCache.appendingPathComponent(UUID().uuidString + ".mov")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: output, to: staging)
                let hash = try LockScreenStore.hash(staging)
                if FileManager.default.fileExists(atPath: cached.path) { try FileManager.default.removeItem(at: cached) }
                try FileManager.default.moveItem(at: staging, to: cached)
                try hash.write(to: checksum, atomically: true, encoding: .utf8)
            }
        }
    }
    private func install(_ output: URL, revision generation: Int, token: LockScreenCancellation) {
        status = "正在備份及套用鎖定影片…"
        activityStage = status; recordingProgress = nil
        io.async { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try token.check(); try self.store.install(output)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == generation else { return }
                    self.busy = false; self.protectsAerial = true; self.clearActivity()
                    self.status = "已同步。可鎖定畫面測試；首次使用請在系統設定選取已下載的航拍桌布"
                    if !self.locked { self.reloadAerial() }
                    self.warmNextDownload()
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.finish(error: error, revision: generation) } }
        }
    }
    private func finish(error: Error, revision generation: Int) {
        guard revision == generation else { return }
        busy = false; lastSource = nil; clearActivity()
        status = "無法同步：\(error.localizedDescription)"
        warmNextDownload()
    }
    func restore() {
        invalidate(); lastSource = nil; enabled = false
        downloads.removeAll(); preparationStatus = ""
        defaults.set(false, forKey: "LockScreenSyncEnabled")
        let generation = revision
        busy = true; status = "正在還原原本的影片與桌布設定…"
        io.async { [weak self] in
            guard let self else { return }
            do {
                try self.store.restore()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == generation else { return }
                    self.restoredThisSession = true
                    self.protectsAerial = false; self.busy = false; self.status = "已停用並還原原本的桌布設定（備份保留）"
                    self.reloadAerial(includeAgent: true)
                }
            } catch { DispatchQueue.main.async { [weak self] in self?.finish(error: error, revision: generation) } }
        }
    }
    private func reloadAerial(includeAgent: Bool = false) {
        if let reloadOverride { reloadOverride(includeAgent); return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-u", String(getuid()), "WallpaperAerialsExtension"] + (includeAgent ? ["WallpaperAgent"] : [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
    func shutdown() { cancellation.cancel(); warming?.cancel() }
}
