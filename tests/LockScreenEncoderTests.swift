import Foundation
import AVFoundation

@main struct LockScreenEncoderTests {
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let cancelled = LockScreenCancellation(); cancelled.cancel()
        do {
            try await LockScreenVideoEncoder.encode(source: source, output: output, cancellation: cancelled)
            fatalError("Cancelled encoding succeeded")
        } catch is CancellationError { }
        assert(!FileManager.default.fileExists(atPath: output.path))
        try await LockScreenVideoEncoder.encode(source: source, output: output, cancellation: LockScreenCancellation())
        let asset = AVURLAsset(url: output)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        assert(videos.count == 1 && audio.isEmpty && duration.seconds >= 180)
        let data = try Data(contentsOf: output)
        assert(data.range(of: Data("tscl".utf8)) != nil && data.range(of: Data("tsas".utf8)) != nil)
        let generator = AVAssetImageGenerator(asset: asset)
        _ = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        print("PASS: cancellation, HEVC decode, silent video, >=180 seconds, temporal sublayers")
    }
}
