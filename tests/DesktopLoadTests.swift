import AppKit
import SwiftUI
import Combine
import AVFoundation
import SpriteKit

final class TestContentModel {
    func warningUnsafeWallpaperModal(which: WEWallpaper) {}
}
final class AppDelegate: NSObject {
    static let shared = AppDelegate()
    var statusItem: NSStatusItem!
    let contentViewModel = TestContentModel()
    static let defaultsSuite = "WE-volume-tests-" + UUID().uuidString
    lazy var wallpaperViewModel = WallpaperViewModel(volumeDefaults: UserDefaults(suiteName: Self.defaultsSuite)!)
    func rebuildWallpaperWindows() {}
    @objc func mute() { wallpaperViewModel.playVolume = 0 }
    @objc func unmute() { wallpaperViewModel.playVolume = wallpaperViewModel.lastPlayVolume }
    @objc func pause() {}
    @objc func resume() {}
}
extension NSMenuItem {
    convenience init(title: String, systemImage: String, action: Selector?, keyEquivalent: String) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
    }
}
extension URL {
    func directoryTotalAllocatedSize(includingSubfolders: Bool) throws -> Int? { 0 }
}

@main struct DesktopLoadTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let defaults = UserDefaults.standard
        let saved = ["ScreenWallpapers", "RecentWallpapers", "EnabledScreens"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        AppDelegate.shared.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        AppDelegate.shared.statusItem.menu = NSMenu()
        let model = AppDelegate.shared.wallpaperViewModel
        let screen = "test-desktop"
        let old = WEWallpaper(using: WEProject(file: "old.mp4", preview: "", title: "Old", type: "video"), where: fixture)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("project.json"))) as? [String: Any]
        let good = WEWallpaper(using: WEProject(file: metadata?["file"] as? String ?? "scene.json", preview: "", title: "New", type: "scene"), where: fixture)
        let bad = WEWallpaper(using: WEProject(file: "missing.json", preview: "", title: "Missing", type: "scene"),
                              where: URL(fileURLWithPath: "/tmp/owe-nonexistent-" + UUID().uuidString))
        model.wallpapers[screen] = old
        var ticks = 0
        var gap = 0.0
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                gap = max(gap, now - previous); previous = now; ticks += 1
            }
        }
        defer { heartbeat.cancel() }
        func settle() async throws {
            for _ in 0..<1000 {
                if model.loadingWallpapers[screen] == nil { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            preconditionFailure("Loading timed out")
        }
        model.setWallpaper(good, for: screen)
        precondition(model.wallpaper(for: screen).project.title == "Old", "Old wallpaper must remain while loading")
        try await Task.sleep(nanoseconds: 30_000_000)
        model.setWallpaper(bad, for: screen)
        try await settle()
        precondition(model.wallpaper(for: screen).project.title == "Old", "Cancelled/failed loads must preserve old wallpaper")
        precondition(model.wallpaperLoadErrors[screen] != nil)
        model.setWallpaper(good, for: screen)
        precondition(model.wallpaperLoadErrors[screen] == nil)
        try await settle()
        precondition(model.wallpaper(for: screen).project.title == "New")
        guard let prepared = model.takePreparedScene(for: screen) else { preconditionFailure("Missing prepared renderer") }
        precondition(ticks > 5 && gap < 0.5, "Preparation must not block main")
        model.playRate = 0
        model.updateMainDisplayAudioSource(screenId: screen)
        model.setVolume(0.3, for: good)
        prepared.activatePreparedScene()
        let background = Mirror(reflecting: prepared).children.first { $0.label == "preparedBackgroundVideo" }?.value as? SceneVideoTexture
        precondition(background != nil && abs(background!.player.volume - 0.3) < 0.001,
                     "Prepared scene must preserve background video audio controls")
        precondition(prepared.skScene is InteractiveWallpaperScene)
        // Exercise actual video decoding after activation, including gifscene.pkg
        // wallpapers whose larger composition layers must not replace the background.
        model.playRate = 1
        let sprite = SKSpriteNode()
        for _ in 0..<100 {
            background!.update(sprite)
            if background!.frameCount >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(background!.frameCount >= 2, "Background video must produce successive frames")
        prepared.stop()
        let movieURL = Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
        let video = WEWallpaper(using: WEProject(file: movieURL.lastPathComponent, preview: "", title: "Ready video", type: "video"),
                                where: movieURL.deletingLastPathComponent())
        model.setWallpaper(video, for: screen)
        precondition(model.wallpaper(for: screen).project.title == "New")
        try await settle()
        precondition(model.wallpaper(for: screen).project.title == "Ready video")
        let readyPlayer = model.takePreparedVideoPlayer(for: screen)
        precondition(readyPlayer?.currentItem?.status == .readyToPlay)
        readyPlayer?.pause()
        print("PASS: retain old until ready, stale selection discarded, failure retains old, prepared scene activates")
        print("Main actor: \(ticks) ticks, longest gap \(gap)s")
    }
}
