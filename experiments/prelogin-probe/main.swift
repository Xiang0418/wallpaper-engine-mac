import AppKit
import AVFoundation
import SystemConfiguration
import OSLog

// Deliberately independent of the wallpaper app, Steam, scripts and user content.
let logger = Logger(subsystem: "org.openwallpaperengine.prelogin-probe", category: "probe")
let lockTest = CommandLine.arguments.contains("--lock-test")
let preview = CommandLine.arguments.contains("--preview") || lockTest
let args = CommandLine.arguments
if !preview {
    guard args.count == 3, args[1] == "--expires",
          let expiry = Double(args[2]), Date().timeIntervalSince1970 < expiry else { exit(0) }
    let user = SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?
    guard user == nil || user == "loginwindow" else { exit(0) }
}

final class PassiveWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var players: [AVQueuePlayer] = []
    var loopers: [AVPlayerLooper] = []
    var playbackCheck: Timer?
    var timeout: Timer?
    var signalSource: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        rebuild()
        playbackCheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (i, player) in self.players.enumerated() {
                let loops = self.loopers[i].loopCount
                let ready = (self.windows[i].contentView?.layer as? AVPlayerLayer)?.isReadyForDisplay ?? false
                logger.notice("Video sample: player=\(i), time=\(player.currentTime().seconds), loops=\(loops), ready=\(ready), status=\(player.timeControlStatus.rawValue)")
                if let error = self.loopers[i].error ?? player.currentItem?.error {
                    logger.error("Video error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        timeout = Timer.scheduledTimer(withTimeInterval: (preview && !lockTest) ? 8 : 90, repeats: false) { _ in
            logger.notice("Probe timed out; exiting")
            NSApp.terminate(nil)
        }
        logger.notice("Probe started; preview=\(preview), lockTest=\(lockTest), windows=\(self.windows.count)")
    }
    @objc func rebuild() {
        players.forEach { $0.pause() }
        loopers.forEach { $0.disableLooping() }
        players.removeAll()
        loopers.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        guard let url = Bundle.main.url(forResource: "test-loop", withExtension: "mov") else {
            logger.error("Bundled movie missing")
            NSApp.terminate(nil)
            return
        }
        for screen in NSScreen.screens {
            let f = screen.frame
            // Only outer 10% strips, with top/bottom 15% untouched.
            // No window exists over the central 80% containing login controls.
            for x in [f.minX, f.maxX - f.width * 0.1] {
                let rect = NSRect(x: x, y: f.minY + f.height * 0.15,
                                  width: f.width * 0.1, height: f.height * 0.7)
                let w = PassiveWindow(contentRect: rect, styleMask: .borderless,
                                      backing: .buffered, defer: false)
                // Local preview uses a floating level so the wallpaper app cannot cover it.
                // Installed pre-login mode keeps its original desktop level.
                w.level = preview ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
                w.canBecomeVisibleWithoutLogin = true
                w.ignoresMouseEvents = true
                w.hasShadow = false
                w.isReleasedWhenClosed = false
                w.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
                let player = AVQueuePlayer()
                player.isMuted = true
                let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = .resize
                layer.frame = v.bounds
                layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                v.wantsLayer = true
                v.layer = layer
                players.append(player)
                loopers.append(looper)
                w.contentView = v
                w.orderFrontRegardless()
                windows.append(w)
                player.play()
            }
        }
        logger.notice("Submitted probe windows: \(self.windows.count); visibility unverified")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let delegate = Delegate()
app.delegate = delegate
app.run()
