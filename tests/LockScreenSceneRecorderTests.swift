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
    func volumePublisher(for wallpaper: WEWallpaper) -> AnyPublisher<Float, Never> { $playVolume.eraseToAnyPublisher() }
}
final class AppDelegate { static let shared = AppDelegate(); let wallpaperViewModel = PlaybackSettings() }

@main struct LockScreenSceneRecorderTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let wallpaper = WEWallpaper(project: .init(file: "scene.json", title: "Export test"), wallpaperDirectory: directory)
        let project = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("project.json"))) as! [String: Any]
        let overrides = LockScreenSceneRecorder.clockOverrides(project: project)
        if directory.lastPathComponent == "3817518265" { precondition(overrides["newproperty2"] as? Bool == false && overrides["newproperty3"] as? Bool == false && overrides["newproperty4"] as? Bool == false) }
        precondition(!overrides.isEmpty)
        let original = ScenePropertyStore.shared.values(at: directory) as NSDictionary
        var ticks = 0
        var longestGap = 0.0
        let heartbeat = Task { @MainActor in
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                longestGap = max(longestGap, now - last); last = now; ticks += 1
            }
        }
        defer { heartbeat.cancel() }
        let target = CGSize(width: Double.random(in: 1500...1520), height: 982)
        let movie = try await LockScreenSceneRecorder.record(wallpaper: wallpaper, targetSize: target, cancellation: LockScreenCancellation())
        precondition(ticks > 50, "Test must perform a fresh recording while the UI heartbeat runs")
        precondition(longestGap < 0.5, "Recording blocked the main actor")
        print("Main actor heartbeat: \(ticks) ticks, longest gap \(longestGap)s")
        let reused = try await LockScreenSceneRecorder.record(wallpaper: wallpaper, targetSize: CGSize(width: target.width * 2, height: target.height * 2), cancellation: LockScreenCancellation())
        let cancelled = LockScreenCancellation()
        do {
            _ = try await LockScreenSceneRecorder.record(wallpaper: wallpaper,
                targetSize: CGSize(width: target.width + 1, height: target.height), cancellation: cancelled,
                progress: { if $0 >= 0.1 { cancelled.cancel() } })
            preconditionFailure("Cancelled export must not finish")
        } catch is CancellationError { }
        precondition(reused == movie, "Same aspect at twice the resolution must reuse the recording")
        precondition(original.isEqual(to: ScenePropertyStore.shared.values(at: directory)))
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        precondition(duration.seconds >= 14.9)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        var images: [Data] = []
        for second in [2, 8] {
            let image = try generator.copyCGImage(at: CMTime(value: Int64(second), timescale: 1), actualTime: nil)
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-\(second).png"))
            images.append(data)
        }
        precondition(images[0] != images[1], "Scene recording must contain motion")
        print("PASS: clock/day/date overrides, original properties unchanged, movie decodes and frames differ")
        print(movie.path)
    }
}
