import AppKit
import ImageIO

struct NowPlayingSnapshot {
    let title: String
    let artist: String
    let playing: Bool
    let artwork: Data?

    static func decode(_ line: Data) -> NowPlayingSnapshot? {
        guard line.count <= 12 * 1024 * 1024,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              message["type"] as? String == "data", message["diff"] as? Bool == false,
              let payload = message["payload"] as? [String: Any] else { return nil }
        let valid = payload["bundleIdentifier"] as? String != nil && payload["title"] as? String != nil
        let artwork = valid ? (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) } : nil
        return NowPlayingSnapshot(title: valid ? (payload["title"] as? String ?? "") : "",
                                  artist: valid ? (payload["artist"] as? String ?? "") : "",
                                  playing: valid && (payload["playing"] as? Bool ?? false), artwork: artwork)
    }

    static func thumbnail(_ data: Data) -> CGImage? {
        guard data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

/// Main-thread lifecycle with bounded JSON-line parsing and image decoding on a
/// worker. The helper is bundled and pinned; no downloads or playback commands.
final class NowPlayingBridge {
    var received: ((NowPlayingSnapshot, CGImage?) -> Void)?
    var failed: (() -> Void)?
    private var process: Process?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "wallpaper.now-playing", qos: .utility)

    func start() {
        guard process == nil else { return }
        let root = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteBridge")
        guard let root,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("MediaRemoteAdapter.framework/MediaRemoteAdapter").path) else {
            failed?(); return
        }
        let token = UUID(); generation = token
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [root.appendingPathComponent("mediaremote-adapter.pl").path,
                             root.appendingPathComponent("MediaRemoteAdapter.framework").path,
                             "stream", "--no-diff", "--debounce=250"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { failed?(); return }
        self.process = process
        queue.async { [weak self] in
            var pending = Data()
            var previousArtwork: Data?
            var previousImage: CGImage?
            defer {
                try? output.fileHandleForReading.close()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.stop(); self.failed?()
                }
            }
            while true {
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 12 * 1024 * 1024 else { return }
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end])
                    pending.removeSubrange(...end)
                    guard let snapshot = NowPlayingSnapshot.decode(line) else { continue }
                    if snapshot.artwork != previousArtwork {
                        previousArtwork = snapshot.artwork
                        previousImage = snapshot.artwork.flatMap(NowPlayingSnapshot.thumbnail)
                    }
                    let image = previousImage
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.received?(snapshot, image)
                    }
                }
            }
        }
    }

    func stop() {
        generation = UUID()
        guard let old = process else { return }
        process = nil
        if old.isRunning { old.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if old.isRunning { kill(old.processIdentifier, SIGKILL) }
        }
    }

    deinit { stop() }
}
