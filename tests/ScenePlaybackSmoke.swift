// Standalone integration harness; compile with the production scene sources.
import AppKit
import AVFoundation
import Combine
import SpriteKit

struct WEWallpaper {
    struct Project { var file: String; var title: String? }
    var project: Project
    var wallpaperDirectory: URL
}
final class PlaybackSettings {
    @Published var playRate: Float = 0
    @Published var playVolume: Float = 0
}
final class AppDelegate {
    static let shared = AppDelegate()
    let wallpaperViewModel = PlaybackSettings()
}

@main struct ScenePlaybackSmoke {
    static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    static func value<T>(_ model: SceneWallpaperViewModel, _ name: String) -> T? {
        Mirror(reflecting: model).children.first { $0.label == name }?.value as? T
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: " + message)
    }
    static func main() throws {
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let parser = try PKGParser(url: fixture.appendingPathComponent("scene.pkg"))
        let scene = try parser.extractJSON(named: "scene.json", as: WEScene.self)!
        check(scene.objects.contains { $0.sound?.first?.hasSuffix(".mp3") == true && $0.playbackmode == "loop" }, "Real scene decodes looping MP3")
        let videos = parser.fileList.filter { $0.hasSuffix(".tex") }.compactMap {
            TEXParser(data: Data(parser.extractFile(named: $0)!)).extractVideoData()
        }
        check(!videos.isEmpty, "Real TEX contains extractable MP4")
        check(TEXParser(data: Data(videos[0].prefix(20))).extractVideoData() == nil, "Rejects bare / truncated MP4 as TEX")
        let wallpaper = WEWallpaper(project: .init(file: "scene.json", title: "Smoke"), wallpaperDirectory: fixture)
        let model = SceneWallpaperViewModel(wallpaper: wallpaper)
        let player: AVQueuePlayer = value(model, "videoPlayer")!
        let audio: [(AVAudioPlayer, Float)] = value(model, "audioPlayers")!
        let directory: URL = value(model, "temporaryDirectory")!
        check(audio.count == 1 && audio[0].0.numberOfLoops == -1, "Creates independent looping music player")
        check(player.rate == 0 && !audio[0].0.isPlaying, "Starts paused when global playback is paused")
        let videoNode = model.skScene!.children.compactMap { $0 as? SKVideoNode }.first!
        check(videoNode.isHidden, "Preview remains before first decoded frame")
        AppDelegate.shared.wallpaperViewModel.playRate = 1
        spin(3)
        check(player.currentItem?.status == .readyToPlay, "AVFoundation accepts extracted real video")
        check(!videoNode.isHidden, "First decoded frame replaces preview")
        check(audio[0].0.isPlaying, "Music resumes with video")
        let asset = player.currentItem!.asset
        print("Video duration: \(CMTimeGetSeconds(asset.duration)); video audio tracks: \(asset.tracks(withMediaType: .audio).count); MP3 duration: \(audio[0].0.duration)")
        AppDelegate.shared.wallpaperViewModel.playRate = 0
        spin(0.2)
        let time = player.currentTime().seconds
        spin(0.3)
        check(abs(player.currentTime().seconds - time) < 0.05 && !audio[0].0.isPlaying, "Pause freezes both timelines")
        AppDelegate.shared.wallpaperViewModel.playVolume = 0.35
        spin(0.2)
        check(abs(player.volume - 0.35) < 0.01 && abs(audio[0].0.volume - 0.35) < 0.01, "Volume reaches video and MP3")
        AppDelegate.shared.wallpaperViewModel.playVolume = 0
        AppDelegate.shared.wallpaperViewModel.playRate = 1
        spin(0.2)
        model.systemWillSleep(Notification(name: NSWorkspace.screensDidSleepNotification))
        check(player.rate == 0 && !audio[0].0.isPlaying, "Sleep pauses both players")
        model.systemDidWake(Notification(name: NSWorkspace.screensDidWakeNotification))
        check(player.rate == 1 && audio[0].0.isPlaying, "Wake restores requested playback")
        let musicTime = audio[0].0.currentTime
        player.seek(to: CMTime(seconds: max(0, asset.duration.seconds - 0.3), preferredTimescale: 600))
        spin(1.5)
        check(player.currentTime().seconds < 3 && player.rate != 0, "Video loops at end")
        check(audio[0].0.currentTime > musicTime, "Video loop does not restart music")
        model.currentWallpaper = WEWallpaper(project: .init(file: "missing.json", title: "Missing"), wallpaperDirectory: fixture)
        check(!FileManager.default.fileExists(atPath: directory.path), "Switch removes extracted media directory")
        check(player.items().isEmpty && !audio[0].0.isPlaying, "Switch stops and releases old media")
        check(model.skScene!.children.contains { ($0 as? SKLabelNode)?.text?.contains("Unable to load scene") == true }, "Missing scene displays failure reason")
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("WE-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: broken) }
        let json = #"{"camera":{},"general":{"orthogonalprojection":{"width":1920,"height":1080}},"objects":[{"image":"missing-model.json","size":"1920 1080","name":"Broken background"},{"image":"icon.json","size":"16 16"}]}"#
        try Data(json.utf8).write(to: broken.appendingPathComponent("scene.json"))
        try Data(#"{"material":"icon-material.json"}"#.utf8).write(to: broken.appendingPathComponent("icon.json"))
        try Data(#"{"passes":[{"textures":["icon"]}]}"#.utf8).write(to: broken.appendingPathComponent("icon-material.json"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: broken.appendingPathComponent("icon.png"))
        try png.write(to: broken.appendingPathComponent("preview.png"))
        model.currentWallpaper = WEWallpaper(project: .init(file: "scene.json", title: "Broken"), wallpaperDirectory: broken)
        let sprites = model.skScene!.children.compactMap { $0 as? SKSpriteNode }
        check(sprites.count == 2, "Small overlay successfully loads alongside preview")
        check(sprites.contains { $0.zPosition == 1_000_000 && !$0.isHidden }, "Failed main background keeps preview above small overlay")
        check(model.skScene!.children.contains { ($0 as? SKLabelNode)?.text?.contains("Broken background") == true }, "Background failure identifies failed object")
        AppDelegate.shared.wallpaperViewModel.playRate = 0
        spin(0.2)
        for _ in 0..<3 {
            model.currentWallpaper = wallpaper
            let temp: URL = value(model, "temporaryDirectory")!
            model.stop()
            check(!FileManager.default.fileExists(atPath: temp.path), "Repeated load/stop leaves no extracted media")
        }
        print("All scene playback checks passed")
    }
}
