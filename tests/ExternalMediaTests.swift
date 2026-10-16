import AppKit
import SpriteKit
import AVFoundation
import CoreAudio

final class FakeMedia: NowPlayingReading {
    var received: ((NowPlayingSnapshot, CGImage?) -> Void)?
    var failed: (() -> Void)?
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}
final class FakeAudio: ExternalAudioCapturing {
    var statusChanged: ((String) -> Void)?
    var changes: [Bool] = []
    func setEnabled(_ value: Bool, retry: Bool) { changes.append(value) }
    var bins = Array<Float>(repeating: 0.5, count: 64)
    func snapshot() -> [Float] { bins }
}

@main struct ExternalMediaTests {
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
        let suite = "ExternalMediaTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = FakeMedia(), audio = FakeAudio()
        let service = ExternalMediaService(defaults: defaults, bridge: bridge, audio: audio)
        let ownMusic = Array<Float>(repeating: 0.25, count: 64)
        check(service.spectrum(wallpaper: ownMusic) == ownMusic, "Wallpaper music works with external audio disabled")
        let first = UUID(), second = UUID()
        service.setConsumer(first, active: true)
        check(bridge.starts == 0 && audio.changes.isEmpty, "Opt-in defaults do not request recording or start helpers")
        service.artworkEnabled = true; service.systemAudioEnabled = true
        check(service.spectrum(wallpaper: ownMusic).allSatisfy { $0 == 0.75 }, "Wallpaper and external music both contribute")
        check(service.spectrum(wallpaper: Array(repeating: 0.8, count: 64)).allSatisfy { $0 == 1 }, "Combined spectrum stays within range")
        audio.bins = Array(repeating: 0, count: 64)
        check(service.spectrum(wallpaper: ownMusic) == ownMusic, "Silent or unavailable external audio preserves wallpaper music")
        audio.bins = Array(repeating: 0.5, count: 64)
        service.setConsumer(second, active: true)
        check(bridge.starts == 1 && audio.changes == [true], "Two displays share one helper and one capture")
        service.setConsumer(first, active: false)
        check(bridge.stops == 0 && audio.changes == [true], "Pausing one display preserves the active display")
        service.setConsumer(second, active: false)
        check(bridge.stops == 1 && audio.changes == [true, false], "Last paused or removed display stops both resources")
        service.setConsumer(first, active: true)
        check(bridge.starts == 2 && audio.changes == [true, false, true], "Resuming reconnects once")
        service.retry()
        check(bridge.starts == 3 && audio.changes.last == true, "Explicit retry restarts failed providers")

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
        check(service.nowPlaying.title == "Track A" && service.nowPlaying.artist == "Artist" && service.nowPlaying.playing, "Script snapshot retains separate title, artist and playback state")
        let revision = service.artworkRevision
        bridge.received?(snapshot, image)
        check(service.artworkRevision == revision, "Unchanged artwork avoids GPU texture recreation")
        bridge.received?(noArtwork, nil)
        check(service.artworkTexture == nil && service.trackTitle == "Track B", "Track without art clears the previous cover")
        bridge.received?(snapshot, image)
        bridge.failed?()
        check(service.artworkTexture == nil && service.trackTitle.isEmpty, "Bridge failure clears stale cover")
        check(service.nowPlaying.title.isEmpty && service.nowPlaying.artist.isEmpty && !service.nowPlaying.playing, "Bridge failure clears script metadata and playback state")
        service.artworkEnabled = false; service.systemAudioEnabled = false
        check(defaults.bool(forKey: "ExternalMedia.audio") == false && defaults.bool(forKey: "ExternalMedia.artwork") == false, "Independent preferences persist")

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

        let samples = (0..<1024).map { sin(2 * Float.pi * 32 * Float($0) / 1024) * 0.5 }
        let sink = SystemAudioSpectrumSink()
        var signalNotifications = 0
        sink.didReceiveSignal = { signalNotifications += 1 }
        sink.consume(channels: [samples, samples.map { -$0 }], at: 10)
        check(signalNotifications == 1, "Real PCM signal is reported for live capture verification")
        check(sink.snapshot(at: 10.01).max()! > 0.1, "Antiphase stereo produces a real spectrum")
        check(sink.snapshot(at: 10.4).allSatisfy { $0 == 0 }, "Stopped callbacks cannot leave a frozen spectrum")
        sink.consume(channels: [Array(repeating: 0, count: 1024)], at: 11)
        check(sink.snapshot(at: 11.01).allSatisfy { $0 == 0 }, "Silence after a gap clears old energy")
        sink.consume(channels: [samples], at: 12); sink.reset()
        check(sink.snapshot(at: 12.01).allSatisfy { $0 == 0 }, "Stopping capture clears PCM and spectrum")

        // Exercise the Process Tap AudioBufferList callback, planar and interleaved.
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            pcm.frameLength = 1024
            for frame in 0..<1024 {
                if interleaved { pcm.floatChannelData![0][frame*2] = samples[frame]; pcm.floatChannelData![0][frame*2+1] = -samples[frame] }
                else { pcm.floatChannelData![0][frame] = samples[frame]; pcm.floatChannelData![1][frame] = -samples[frame] }
            }
            sink.reset(); sink.consume(bufferList: pcm.audioBufferList)
            check(sink.snapshot().max()! > 0.1, "Process Tap PCM conversion \(interleaved ? "interleaved" : "planar")")
        }
        service.artworkEnabled = true; service.systemAudioEnabled = true
        let stopsBeforeShutdown = bridge.stops
        service.shutdown()
        check(bridge.stops == stopsBeforeShutdown + 1 && audio.changes.last == false, "App shutdown releases active media resources")
        print("External media tests passed")
    }
}
