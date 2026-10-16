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


@main struct PresetPlaybackTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("we-preset-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let preset = root.appendingPathComponent("3169242171")
        let base = root.appendingPathComponent("3122339805")
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: preset)
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: base)
        let original = try Data(contentsOf: preset.appendingPathComponent("project.json"))
        let project = try JSONDecoder().decode(WEProject.self, from: original)
        precondition(project.type == "preset" && project.dependency?.rawValue == "3122339805")
        let wallpaper = try await WEPresetResolver.prepare(WEWallpaper(using: project, where: preset))
        precondition(wallpaper.project.type == "scene" && wallpaper.project.title == project.title)
        precondition(wallpaper.wallpaperDirectory == preset)
        let preserved = try Data(contentsOf: preset.appendingPathComponent("project.json"))
        precondition(preserved == original)
        let properties = ScenePropertyStore.shared.values(at: preset)
        precondition(properties["middleimagewindowheader"] as? String == "Miku OS")
        precondition(properties["customimagemiddle"] as? String == "files/tumblr_6dda819c34d190fafdc0681a23a28ca8_41eac308_400.gif")
        let model = SceneWallpaperViewModel(wallpaper: wallpaper)
        precondition(model.loadFailure == nil, model.loadFailure ?? "")
        guard let scene = model.skScene else { fatalError("No scene") }
        let sprites = scene.descendants.compactMap { $0 as? SKSpriteNode }
        let custom = sprites.filter { $0.userData?["presetTexture"] != nil }
        precondition(custom.count == 3, "Expected all three preset GIF bindings, got \(custom.count)")
        let firstTextures = custom.map { $0.texture }
        scene.isPaused = false
        for tick in 0...30 { scene.update(Double(tick) / 30) }
        precondition(zip(custom, firstTextures).allSatisfy { $0.0.texture !== $0.1 }, "All three GIFs must advance frames")
        print("PASS: real preset resolves, retains identity and metadata, applies settings and animates all three GIFs")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        scene.update(2)
        precondition(model.renderingWarnings.isEmpty, "Unexpected rendering warnings: \(model.renderingWarnings)")
        guard let interactive = scene as? InteractiveWallpaperScene, let runtime = interactive.scriptRuntime else { fatalError("Missing runtime") }
        func layer(_ id: Int) -> SKNode { scene.childNode(withName: "//layer:" + String(id))! }
        func label(_ id: Int) -> String { (layer(id).children.first as? SKLabelNode)?.attributedText?.string ?? "" }
        func media(_ title: String, _ artist: String, _ playing: Bool, enabled: Bool = true) {
            runtime.applyMedia(title: title, artist: artist, playing: playing, enabled: enabled)
            runtime.update(delta: 0.016, cursor: CGPoint(x: -1000, y: -1000))
        }
        media("測試歌曲 First Track", "測試歌手", true)
        precondition(label(60) == "測試歌曲 First Track" && label(88) == "測試歌手")
        precondition(label(125) == "Playing" && layer(584).isHidden && !layer(101).isHidden)
        media("測試歌曲 First Track", "測試歌手", false)
        precondition(label(125) == "Paused" && layer(584).isHidden)
        media("Second Track", "Second Artist", true)
        precondition(label(60) == "Second Track" && label(88) == "Second Artist")
        media("", "", false)
        precondition(label(60).isEmpty && !layer(584).isHidden && label(125).isEmpty)
        media("Should clear", "Artist", true, enabled: false)
        precondition(label(60).isEmpty && !layer(584).isHidden)
        precondition(runtime.diagnostics.isEmpty, "Media handlers failed: \(runtime.diagnostics)")
        print("PASS: actual preset handlers display title/artist and distinguish playing, paused, stopped, disabled and track changes")
        if CommandLine.arguments.contains("--live-media") {
            let service = ExternalMediaService.shared
            service.artworkEnabled = true
            let deadline = Date().addingTimeInterval(15)
            while (service.nowPlaying.title.isEmpty || service.artworkTexture == nil) && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
                scene.update(ProcessInfo.processInfo.systemUptime)
            }
            scene.update(ProcessInfo.processInfo.systemUptime)
            precondition(!service.nowPlaying.title.isEmpty && service.artworkTexture != nil, "No live music/artwork from bridge")
            precondition(label(60) == service.nowPlaying.title && label(88) == service.nowPlaying.artist)
            precondition(layer(584).isHidden && !layer(101).isHidden)
            precondition((layer(101).children.first as? SKSpriteNode)?.texture != nil)
            print("PASS: live macOS song title, artist, playback and artwork reach the rendered preset")
            print("Live title: \(label(60)); artist: \(label(88)); state: \(label(125))")
        }
        scene.scaleMode = .fill
        let screen = NSScreen.main!
        let topInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let view = SKView(frame: NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height - topInset))
        view.presentScene(scene)
        let lower = scene.convertPoint(toView: .zero)
        let upper = scene.convertPoint(toView: CGPoint(x: scene.size.width, y: scene.size.height))
        precondition(min(lower.x, upper.x) >= -0.1 && max(lower.x, upper.x) <= view.bounds.width + 0.1)
        precondition(min(lower.y, upper.y) >= -0.1 && max(lower.y, upper.y) <= view.bounds.height + 0.1)
        precondition(abs(min(lower.x, upper.x)) < 0.1 && abs(max(lower.x, upper.x) - view.bounds.width) < 0.1)
        precondition(abs(min(lower.y, upper.y)) < 0.1 && abs(max(lower.y, upper.y) - view.bounds.height) < 0.1)
        print("PASS: entire scene fills the usable desktop edge to edge, with no clipping or letterboxing (menu inset \(topInset))")
        if let texture = view.texture(from: scene) {
            let bitmap = NSBitmapImageRep(cgImage: texture.cgImage())
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/we-miku-media.png"))
        }
        print("Warnings: \(model.renderingWarnings)")
        model.stop()
        // Cycles fail before materialization and cannot replace a working cache.
        var raw = try WEPresetResolver.metadata(base)
        raw["dependency"] = "3169242171"
        try JSONSerialization.data(withJSONObject: raw).write(to: base.appendingPathComponent("project.json"))
        do { _ = try await WEPresetResolver.prepare(WEWallpaper(using: project, where: preset)); fatalError("Cycle accepted") }
        catch { precondition(error.localizedDescription.contains("cycle")) }
        precondition(fm.fileExists(atPath: preset.appendingPathComponent(".preset-runtime/project.json").path))
        print("PASS: dependency cycles rejected; working cache preserved")
    }
}

extension SKNode { var descendants: [SKNode] { children.flatMap { [$0] + $0.descendants } } }
