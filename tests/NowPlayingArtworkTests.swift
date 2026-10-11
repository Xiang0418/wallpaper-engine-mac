import AppKit
import SpriteKit

final class FakeMedia: NowPlayingReading {
    var received: ((NowPlayingSnapshot, CGImage?) -> Void)?
    var failed: (() -> Void)?
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@main struct NowPlayingArtworkTests {
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); print("PASS: " + label)
    }
    static func message(_ payload: [String: Any], diff: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type":"data", "diff":diff, "payload":payload])
    }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--live-now-playing") {
            let bridge = NowPlayingBridge()
            var connected = false, failed = false
            bridge.received = { snapshot, image in
                if !snapshot.title.isEmpty && image != nil { connected = true }
            }
            bridge.failed = { failed = true }
            bridge.start()
            let deadline = Date().addingTimeInterval(10)
            while !connected && !failed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            bridge.stop()
            check(connected, "Bundled live bridge delivers current player metadata and decoded artwork")
            return
        }
        let suite = "NowPlayingArtworkTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = FakeMedia()
        let service = NowPlayingArtworkService(defaults: defaults, bridge: bridge)
        let first = UUID(), second = UUID()
        service.setConsumer(first, active: true)
        check(bridge.starts == 0, "Opt-in defaults do not request start the bridge")
        service.artworkEnabled = true
        service.setConsumer(second, active: true)
        check(bridge.starts == 1, "Two displays share one bridge")
        service.setConsumer(first, active: false)
        check(bridge.stops == 0, "Pausing one display preserves the active display")
        service.setConsumer(second, active: false)
        check(bridge.stops == 1, "Last paused or removed display stops the bridge")
        service.setConsumer(first, active: true)
        check(bridge.starts == 2, "Resuming reconnects once")
        service.retry()
        check(bridge.starts == 3, "Explicit retry restarts failed providers")

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(bridge.stops == 3, "System sleep stops the bridge")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(bridge.starts == 4, "System wake reconnects active scenes")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 900,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let snapshot = NowPlayingSnapshot.decode(try message(["bundleIdentifier":"org.test.player", "title":"Track A", "artist":"Artist", "playing":true, "artworkData":png.base64EncodedString()]))!
        let image = NowPlayingSnapshot.thumbnail(snapshot.artwork!)!
        check(image.width == 1024 && image.height == 576, "Large artwork is decoded to a bounded thumbnail")
        check(NowPlayingSnapshot.decode(Data("invalid".utf8)) == nil, "Malformed bridge output is rejected")
        let diffMessage = try message([:], diff: true)
        check(NowPlayingSnapshot.decode(diffMessage) == nil, "Unexpected partial payload cannot become stale full state")
        let empty = NowPlayingSnapshot.decode(try message([:]))!
        check(empty.artwork == nil && empty.title.isEmpty, "Empty player resets state")
        let noArtwork = NowPlayingSnapshot.decode(try message(["bundleIdentifier":"org.test.player", "title":"Track B", "playing":true]))!
        bridge.received?(snapshot, image)
        check(service.artworkTexture != nil && service.trackTitle.contains("Track A"), "Metadata updates shared artwork")
        let revision = service.artworkRevision
        bridge.received?(snapshot, image)
        check(service.artworkRevision == revision, "Unchanged artwork avoids GPU texture recreation")
        bridge.received?(noArtwork, nil)
        check(service.artworkTexture == nil && service.trackTitle == "Track B", "Track without art clears the previous cover")
        bridge.received?(snapshot, image)
        bridge.failed?()
        check(service.artworkTexture == nil && service.trackTitle.isEmpty, "Bridge failure clears stale cover")
        service.artworkEnabled = false
        check(defaults.bool(forKey: "ExternalMedia.artwork") == false, "Artwork preference persists")

        let sprite = SKSpriteNode(color: .white, size: CGSize(width: 300, height: 300))
        let original = SKTexture(cgImage: image); sprite.texture = original
        let shader = SKShader(source: "void main() { gl_FragColor = texture2D(u_texture, v_tex_coord); }")
        sprite.shader = shader
        let binding = SceneMediaArtworkBinding(sprite: sprite)
        binding.apply(SKTexture(cgImage: image))
        check(abs(sprite.texture!.size().width - sprite.texture!.size().height) < 1, "YouTube widescreen thumbnail is cropped without stretching")
        check(sprite.shader === shader && sprite.size == CGSize(width: 300, height: 300), "Material shader and authored size survive replacement")
        binding.apply(nil)
        check(sprite.texture === original, "Missing artwork restores the original texture")
        let material = try JSONDecoder().decode(WEMaterial.self, from: Data(#"{"passes":[{"usertextures":[{"name":"$mediaThumbnail","type":"system"}]}]}"#.utf8))
        check(material.passes!.first!.usesMediaThumbnail, "Standard system media binding is recognized")

        service.artworkEnabled = true
        let stopsBeforeShutdown = bridge.stops
        service.shutdown()
        check(bridge.stops == stopsBeforeShutdown + 1, "App shutdown releases active media resources")
        print("Artwork tests passed")
    }
}
