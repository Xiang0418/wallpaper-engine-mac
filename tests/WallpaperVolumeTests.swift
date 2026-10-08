import AppKit
import SwiftUI
import Combine
import AVFoundation

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

@main struct WallpaperVolumeTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        print("PASS: " + message)
    }
    static func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.001 }
    static func main() throws {
        _ = NSApplication.shared
        AppDelegate.shared.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        AppDelegate.shared.statusItem.menu = NSMenu()
        defer {
            NSStatusBar.system.removeStatusItem(AppDelegate.shared.statusItem)
            UserDefaults(suiteName: AppDelegate.defaultsSuite)?.removePersistentDomain(forName: AppDelegate.defaultsSuite)
        }
        let suite = "WE-volume-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WallpaperViewModel(volumeDefaults: defaults)
        let a = WEWallpaper(using: WEProject(file: "scene.json", preview: "", title: "Background music", type: "scene"), where: URL(fileURLWithPath: "/tmp/wallpaper-a"))
        let b = WEWallpaper(using: WEProject(file: "video.mp4", preview: "", title: "Other wallpaper", type: "video"), where: URL(fileURLWithPath: "/tmp/wallpaper-b"))
        check(model.volume(for: a) == 1, "New wallpapers default to 100%")
        var received: Float = -1
        let observation = model.volumePublisher(for: a).sink { received = $0 }
        defer { observation.cancel() }
        model.setVolume(0.37, for: a)
        check(close(received, 0.37) && model.volume(for: b) == 1, "Changes publish immediately and isolate wallpapers")
        model.updateMainDisplayAudioSource(screenId: "saved-audio-screen")
        let restored = WallpaperViewModel(volumeDefaults: defaults)
        check(restored.audioSourceScreenId == WallpaperViewModel.mainScreenId(), "Restart follows system main display rather than stale source preference")
        check(close(restored.volume(for: a), 0.37), "Volume survives settings reload")
        var renamed = a
        renamed.project.title = "Renamed"
        check(close(model.volume(for: renamed), 0.37), "Renaming retains volume identity")
        model.playVolume = 0
        model.setVolume(0.62, for: a)
        check(received == 0 && close(model.volume(for: a), 0.62), "Changing saved volume while muted stays silent")
        model.playVolume = model.lastPlayVolume
        check(close(received, 0.62), "Unmute restores saved wallpaper volume")
        model.setVolume(-1, for: a)
        check(received == 0, "Lower endpoint clamps to zero")
        model.setVolume(2, for: a)
        model.setVolume(.nan, for: a)
        check(received == 1, "Upper endpoint clamps and invalid values are ignored")
        model.setVolume(0.37, for: a)
        let menu = WallpaperVolumeMenuView(model: model, wallpaper: a, screenName: "Built-in Display")
        let peer = WallpaperVolumeMenuView(model: model, wallpaper: a, screenName: "External Display")
        let slider = menu.subviews.compactMap { $0 as? NSSlider }.first!
        let peerSlider = peer.subviews.compactMap { $0 as? NSSlider }.first!
        slider.doubleValue = 43
        slider.sendAction(slider.action, to: slider.target)
        check(close(model.volume(for: a), 0.43) && peerSlider.intValue == 43, "Menu slider updates model and another screen control")
        model.setVolume(0.21, for: a)
        check(slider.intValue == 21, "Settings changes update existing menu control")
        check(slider.accessibilityLabel()?.contains("Background music") == true, "Menu slider has wallpaper-specific accessibility label")

        let overall = WallpaperVolumeMenuView(model: model)
        let overallSlider = overall.subviews.compactMap { $0 as? NSSlider }.first!
        overallSlider.doubleValue = 40
        overallSlider.sendAction(overallSlider.action, to: overallSlider.target)
        check(close(model.playVolume, 0.4) && close(model.volume(for: a), 0.21), "Single overall slider preserves wallpaper levels")
        check(close(model.effectiveVolume(for: a), 0.084), "Overall volume multiplies saved wallpaper volume")
        model.playVolume = 0
        check(overallSlider.intValue == 0, "Mute updates overall slider")
        model.playVolume = model.lastPlayVolume
        check(overallSlider.intValue == 40, "Unmute restores overall percentage")

        let menuToCopy = NSMenu()
        let volumeItem = NSMenuItem()
        volumeItem.view = overall
        menuToCopy.addItem(volumeItem)
        let copiedMenu = menuToCopy.copy() as! NSMenu
        check(copiedMenu.items.first?.view is WallpaperVolumeMenuView, "Copying a custom-volume menu safely decodes its view")

        AppDelegate.shared.wallpaperViewModel.playVolume = 0.23
        let copiedSlider = copiedMenu.items.first!.view!.subviews.compactMap { $0 as? NSSlider }.first!
        check(copiedSlider.intValue == 23, "Decoded menu remains bound to live master volume")
        AppDelegate.shared.wallpaperViewModel.playVolume = 1

        model.wallpapers = ["display-a": a, "display-b": b]
        model.selectedScreenId = "display-b"
        model.updateMainDisplayAudioSource(screenId: "display-a")
        check(model.currentWallpaper.wallpaperDirectory == b.wallpaperDirectory, "Audio main display does not change wallpaper editing selection")
        model.currentWallpaper = a
        check(model.wallpaper(for: "display-a").wallpaperDirectory == a.wallpaperDirectory && model.wallpaper(for: "display-b").wallpaperDirectory == a.wallpaperDirectory,
              "Wallpaper picker changes only its selected display")
        model.currentWallpaper = b
        model.updateMainDisplayAudioSource(screenId: "display-b")
        check(model.wallpaper(for: "display-a").wallpaperDirectory == a.wallpaperDirectory && model.wallpaper(for: "display-b").wallpaperDirectory == b.wallpaperDirectory,
              "Changing main display preserves different wallpapers on both screens")

        // Actual video player subscriptions must follow the wallpaper when switching.
        let shared = AppDelegate.shared.wallpaperViewModel
        shared.playRate = 0 // no audible playback during the test
        shared.setVolume(0.32, for: a)
        shared.setVolume(0.71, for: b)
        shared.updateMainDisplayAudioSource(screenId: "test-video")
        let video = VideoWallpaperViewModel(wallpaper: a, screenId: "test-video")
        check(close(video.player.volume, 0.32), "Video starts with saved wallpaper volume")
        video.currentWallpaper = b
        check(close(video.player.volume, 0.71), "Switching video rebinds saved volume")
        shared.setVolume(0.15, for: a)
        check(close(video.player.volume, 0.71), "Previous wallpaper settings no longer affect player")
        shared.playVolume = 0
        check(video.player.volume == 0, "Global mute reaches video player")
        shared.playVolume = 1
        check(close(video.player.volume, 0.71), "Unmute preserves video wallpaper level")

        if CommandLine.arguments.count > 1 {
            let wallpaper = WEWallpaper(using: WEProject(file: "scene.json", preview: "", title: "Scene fixture", type: "scene"), where: URL(fileURLWithPath: CommandLine.arguments[1]))
            shared.setVolume(0.44, for: wallpaper)
            shared.updateMainDisplayAudioSource(screenId: "test-scene")
            let scene = SceneWallpaperViewModel(wallpaper: wallpaper, screenId: "test-scene")
            defer { scene.stop() }
            let properties = Mirror(reflecting: scene).children
            let player = properties.first { $0.label == "videoPlayer" }!.value as! AVQueuePlayer
            let audio = properties.first { $0.label == "audioPlayers" }!.value as! [(AVAudioPlayer, Float)]
            check(close(player.volume, 0.44) && close(audio[0].0.volume, 0.44), "Scene starts with saved volume on video and MP3")
            shared.setVolume(0.28, for: wallpaper)
            check(close(player.volume, 0.28) && close(audio[0].0.volume, 0.28), "Scene slider changes both media players immediately")
            shared.playVolume = 0
            shared.setVolume(0.52, for: wallpaper)
            check(player.volume == 0 && audio[0].0.volume == 0, "Scene remains muted while its saved volume changes")
            shared.playVolume = 1
            check(close(player.volume, 0.52) && close(audio[0].0.volume, 0.52), "Scene unmute restores its saved percentage")
            shared.updateMainDisplayAudioSource(screenId: "test-video")
            check(close(video.player.volume, 0.71) && player.volume == 0 && audio[0].0.volume == 0,
                  "Changing main screen transfers sound between different wallpapers")
            shared.updateMainDisplayAudioSource(screenId: "test-scene")
            check(video.player.volume == 0 && close(audio[0].0.volume, 0.52),
                  "Switching main screen back restores only its own wallpaper audio")
            // Repeated renderer replacement models display notifications during lid changes.
            shared.updateMainDisplayAudioSource(screenId: "wake-display-a")
            let first = SceneWallpaperViewModel(wallpaper: wallpaper, screenId: "wake-display-a")
            let second = SceneWallpaperViewModel(wallpaper: wallpaper, screenId: "wake-display-b")
            scene.stop()
            func music(_ model: SceneWallpaperViewModel) -> AVAudioPlayer {
                (Mirror(reflecting: model).children.first { $0.label == "audioPlayers" }!.value as! [(AVAudioPlayer, Float)])[0].0
            }
            NotificationCenter.default.post(name: ScenePropertyStore.didChange,
                object: wallpaper.wallpaperDirectory.standardizedFileURL.path, userInfo: ["appdockenabled": true])
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check(first.skScene?.childNode(withName: "//layer:146")?.isHidden == false && second.skScene?.childNode(withName: "//layer:146")?.isHidden == false,
                  "One property update changes both live display scenes")
            NotificationCenter.default.post(name: ScenePropertyStore.didChange,
                object: "/different-wallpaper", userInfo: ["appdockenabled": false])
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            check(first.skScene?.childNode(withName: "//layer:146")?.isHidden == false,
                  "Other wallpapers cannot change this scene's settings")
            let firstMusic = music(first)
            let secondMusic = music(second)
            check([firstMusic, secondMusic].filter { $0.volume > 0 }.count == 1, "Same wallpaper on two displays has one audible music player")
            var retained = [first]
            for _ in 0..<3 {
                let oldMusic = music(retained.last!)
                let replacement = SceneWallpaperViewModel(wallpaper: wallpaper, screenId: "wake-display-a")
                retained.append(replacement)
                check(!oldMusic.isPlaying, "Replacing a display stops its previous player even while retained")
                check([music(replacement), secondMusic].filter { $0.volume > 0 }.count == 1, "Repeated display replacement keeps exactly one audio owner")
            }
            // Delayed teardown from an old view cannot unregister its replacement.
            first.stop()
            WallpaperPlaybackSessions.shared.stop(screenId: "wake-display-a")
            check(secondMusic.volume == 0, "Disconnecting selected source does not enable another display")
            shared.updateMainDisplayAudioSource(screenId: "wake-display-b")
            check(secondMusic.volume > 0, "Selecting another display transfers audio ownership")
            let reconnected = SceneWallpaperViewModel(wallpaper: wallpaper, screenId: "wake-display-a")
            check(music(reconnected).volume == 0, "Reconnecting a nonselected screen stays silent")
            reconnected.stop()
            for retired in retained {
                retired.systemDidWake(Notification(name: NSWorkspace.screensDidWakeNotification))
                check((Mirror(reflecting: retired).children.first { $0.label == "audioPlayers" }!.value as! [(AVAudioPlayer, Float)]).isEmpty,
                      "Retired renderer stays stopped after wake")
            }
            second.stop()

        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 400))
            content.wantsLayer = true
            content.appearance = NSAppearance(named: appearance)
            content.layer?.backgroundColor = (name == "light" ? NSColor.white : NSColor.windowBackgroundColor).cgColor
            let menuPreview = WallpaperVolumeMenuView(model: model)
            menuPreview.frame.origin = NSPoint(x: 20, y: 138)
            content.addSubview(menuPreview)
            let source = NSHostingView(rootView: WallpaperAudioSourceControl(wallpaperViewModel: model).padding(16).environment(\.colorScheme, name == "light" ? .light : .dark))
            source.frame = NSRect(x: 0, y: 265, width: 340, height: 130)
            content.addSubview(source)
            let settings = NSHostingView(rootView: WallpaperVolumeControl(wallpaperViewModel: model, wallpaper: a).padding(16).environment(\.colorScheme, name == "light" ? .light : .dark))
            settings.frame = NSRect(x: 0, y: 0, width: 340, height: 130)
            content.addSubview(settings)
            let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = content
            window.appearance = content.appearance
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/we-volume-\(name).png"))
        }
        print("All wallpaper volume checks passed")
    }
}
