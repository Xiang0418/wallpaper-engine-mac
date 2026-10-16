import AppKit
import Combine

// Minimal app-model fixtures; the synchronization service and file store are production code.
struct WEProject: Codable { var title = "Test wallpaper"; var type = "video"; var file: String }
struct WEWallpaper {
    var wallpaperDirectory: URL; var project: WEProject
    init(wallpaperDirectory: URL, project: WEProject) { self.wallpaperDirectory = wallpaperDirectory; self.project = project }
    init(using project: WEProject, where directory: URL) { self.init(wallpaperDirectory: directory, project: project) }
}
final class WallpaperViewModel {
    @Published var wallpapers: [String: WEWallpaper] = [:]
    var selectedScreenId = "display"
    static func mainScreenId() -> String { "display" }
    static func screenId(for screen: NSScreen) -> String { "display" }
}
final class LockScreenCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
}
final class EncodeCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
enum LockScreenVideoEncoder {
    static let counter = EncodeCounter()
    static func encode(source: URL, output: URL, cancellation: LockScreenCancellation) async throws {
        try await Task.sleep(nanoseconds: source.lastPathComponent == "slow.mov" ? 400_000_000 : 30_000_000)
        try cancellation.check()
        counter.increment()
        try Data(contentsOf: source).write(to: output)
    }
}
enum ScenePropertyStore { static let didChange = Notification.Name("ScenePropertiesDidChange") }
enum LockScreenSceneRecorder {
    static func record(wallpaper: WEWallpaper, targetSize: CGSize? = nil, cancellation: LockScreenCancellation, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try cancellation.check()
        progress(0.5)
        try await Task.sleep(nanoseconds: 80_000_000)
        return wallpaper.wallpaperDirectory.appendingPathComponent("fast.mov")
    }
}
@main struct LockScreenSyncTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let videos = root.appendingPathComponent("videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("Index.plist")
        let slot = videos.appendingPathComponent(UUID().uuidString + ".mov")
        for (url,text) in [(settings,"settings"),(slot,"original"),(root.appendingPathComponent("slow.mov"),"slow"),(root.appendingPathComponent("fast.mov"),"latest")] {
            try Data(text.utf8).write(to: url)
        }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LockScreenStore(root: root.appendingPathComponent("backup"), videos: videos, settings: settings)
        var connected = [LockScreenDisplay(id: "display", name: "Built-in", size: CGSize(width: 1512, height: 982)),
                         LockScreenDisplay(id: "external", name: "External", size: CGSize(width: 1920, height: 1080))]
        var main = "display"
        let service = LockScreenSyncService(store: store, defaults: defaults, reload: { _ in },
            displays: { connected }, mainDisplay: { main }, movieCache: root.appendingPathComponent("cache"))
        let model = WallpaperViewModel()
        model.wallpapers["display"] = WEWallpaper(wallpaperDirectory: root, project: WEProject(file: "slow.mov"))
        service.start(model: model); service.setEnabled(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        model.wallpapers["display"] = WEWallpaper(wallpaperDirectory: root, project: WEProject(file: "fast.mov"))
        try await Task.sleep(nanoseconds: 600_000_000)
        assert(service.activityTitle.isEmpty && service.recordingProgress == nil, "Completed jobs clear progress")
        let latest = try String(contentsOf: slot, encoding: .utf8)
        assert(latest == "latest" && !service.busy && service.protectsAerial)
        let download = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        try Data("downloaded".utf8).write(to: download.appendingPathComponent("new.mov"))
        try JSONEncoder().encode(WEProject(file: "new.mov")).write(to: download.appendingPathComponent("project.json"))
        NotificationCenter.default.post(name: Notification.Name("WorkshopDownloadCompleted"), object: download)
        try await Task.sleep(nanoseconds: 200_000_000)
        let unchanged = try String(contentsOf: slot, encoding: .utf8)
        assert(unchanged == "latest", "Download must not replace the active lock wallpaper")
        assert(service.preparationStatus.contains("已準備好"))
        let warmedCount = LockScreenVideoEncoder.counter.value
        model.wallpapers["display"] = WEWallpaper(wallpaperDirectory: download, project: WEProject(file: "new.mov"))
        try await Task.sleep(nanoseconds: 200_000_000)
        assert(LockScreenVideoEncoder.counter.value == warmedCount, "Selection must reuse download preparation")
        let downloaded = try String(contentsOf: slot, encoding: .utf8)
        assert(downloaded == "downloaded")
        model.wallpapers["display"] = WEWallpaper(wallpaperDirectory: root, project: WEProject(file: "fast.mov"))
        try await Task.sleep(nanoseconds: 200_000_000)
        let encodes = LockScreenVideoEncoder.counter.value
        service.retry()
        try await Task.sleep(nanoseconds: 200_000_000)
        assert(LockScreenVideoEncoder.counter.value == encodes, "Same movie reuses Aerial cache")
        model.wallpapers["external"] = WEWallpaper(wallpaperDirectory: root, project: WEProject(file: "slow.mov"))
        main = "external"
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(nanoseconds: 1_600_000_000)
        let external = try String(contentsOf: slot, encoding: .utf8)
        assert(service.activeDisplayName == "External" && external == "slow")
        main = "display"; connected.removeLast()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let restoredDisplay = try String(contentsOf: slot, encoding: .utf8)
        assert(service.activeDisplayName == "Built-in" && restoredDisplay == "latest")
        assert(LockScreenVideoEncoder.counter.value == encodes + 1, "Returning to old display uses cache")
        // A corrupt cached movie must be regenerated, never installed.
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("cache"), includingPropertiesForKeys: nil)
        for file in cacheFiles where file.pathExtension == "mov" { try Data("corrupt".utf8).write(to: file) }
        service.retry()
        try await Task.sleep(nanoseconds: 200_000_000)
        assert(LockScreenVideoEncoder.counter.value == encodes + 2)
        model.wallpapers["display"] = WEWallpaper(wallpaperDirectory: root, project: WEProject(type: "web", file: "index.html"))
        try await Task.sleep(nanoseconds: 50_000_000)
        assert(service.status.contains("不是影片或場景"))
        model.wallpapers["display"] = WEWallpaper(wallpaperDirectory: root, project: WEProject(file: "slow.mov"))
        try await Task.sleep(nanoseconds: 50_000_000)
        model.wallpapers["display"] = WEWallpaper(wallpaperDirectory: root, project: WEProject(type: "Scene", file: "scene.json"))
        try await Task.sleep(nanoseconds: 600_000_000)
        let scene = try String(contentsOf: slot, encoding: .utf8)
        assert(scene == "latest" && !service.busy)
        service.retry()
        try await Task.sleep(nanoseconds: 40_000_000)
        assert(service.recordingProgress == 0.5 && service.activityStage.contains("錄製"))
        try await Task.sleep(nanoseconds: 150_000_000)
        assert(service.activityTitle.isEmpty && service.recordingProgress == nil)
        model.wallpapers["display"] = WEWallpaper(wallpaperDirectory: root, project: WEProject(file: "slow.mov"))
        try await Task.sleep(nanoseconds: 50_000_000)
        service.setEnabled(false)
        try await Task.sleep(nanoseconds: 600_000_000)
        let original = try String(contentsOf: slot, encoding: .utf8)
        assert(original == "original" && !service.busy && !service.protectsAerial && !service.enabled)
        assert(service.suspendsDesktopOverrides, "Quitting must not overwrite the restored system configuration")
        print("PASS: newest selection wins, unsupported wallpaper retains movie, disable cancels and restores")
    }
}
