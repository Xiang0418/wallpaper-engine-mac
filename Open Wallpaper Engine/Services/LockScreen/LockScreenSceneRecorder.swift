import AppKit
import AVFoundation
import SpriteKit
import Metal
import CryptoKit

/// Renders only our own scene into a movie. No desktop/screen recording permission is needed.
enum LockScreenSceneRecorder {
    static func clockOverrides(project: [String: Any]) -> [String: Any] {
        let general = project["general"] as? [String: Any] ?? [:]
        let properties = general["properties"] as? [String: [String: Any]] ?? [:]
        var overrides: [String: Any] = [:]
        for (key, value) in properties where value["type"] as? String == "bool" {
            let label = (value["text"] as? String ?? key).lowercased()
            if ["clock", "time switch", "date switch", "day switch", "时间", "時鐘", "時間", "日期", "礼拜", "星期"].contains(where: label.contains) {
                overrides[key] = false
            }
        }
        return overrides
    }

    static func record(wallpaper: WEWallpaper, targetSize: CGSize? = nil, cancellation: LockScreenCancellation, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let assets = await MainActor.run { EngineAssetLibrary.standard.activeRoot }
        return try await withCheckedThrowingContinuation { continuation in
            recordingQueue.async {
                do {
                    let result = try autoreleasepool {
                        try recordOnQueue(wallpaper: wallpaper, targetSize: targetSize, cancellation: cancellation,
                                          progress: progress, assets: assets)
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // The export scene, JavaScript runtime and renderer belong exclusively to this queue.
    private static let recordingQueue = DispatchQueue(label: "com.openwallpaper.scene-recording", qos: .utility)
    private static func recordOnQueue(wallpaper: WEWallpaper, targetSize: CGSize?,
                                     cancellation: LockScreenCancellation, progress: @escaping @Sendable (Double) -> Void,
                                     assets: URL?) throws -> URL {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let fm = FileManager.default
        let directory = wallpaper.wallpaperDirectory
        let projectData = try Data(contentsOf: directory.appendingPathComponent("project.json"))
        let project = try JSONSerialization.jsonObject(with: projectData) as? [String: Any] ?? [:]
        let overrides = clockOverrides(project: project)
        let properties = ScenePropertyStore.shared.values(at: directory).merging(overrides) { _, new in new }
        var recipe = try JSONSerialization.data(withJSONObject: properties, options: [.sortedKeys])
        recipe.append(projectData)
        recipe.append(Data((directory.path + "scene-lock-v4-background-safe-audio-15s-30fps").utf8))
        let aspect = targetSize.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil }
        recipe.append(Data(("aspect:" + String(format: "%.6f", aspect ?? 0)).utf8))
        for file in [wallpaper.project.file, (wallpaper.project.file as NSString).deletingPathExtension + ".pkg"] {
            let values = try? directory.appendingPathComponent(file).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            recipe.append(Data("\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))
        }
        let key = SHA256.hash(data: recipe).map { String(format: "%02x", $0) }.joined()
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Open Wallpaper Engine/LockScreenScenes")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let result = cache.appendingPathComponent(key + ".mov")
        try cancellation.check()
        if fm.fileExists(atPath: result.path) { return result }
        progress(0)
        let temporary = cache.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? fm.removeItem(at: temporary) }
        let model = SceneWallpaperViewModel(wallpaper: wallpaper, sharedAssets: { assets }, exportProperties: properties)
        defer { model.stop() }
        guard let scene = model.skScene as? InteractiveWallpaperScene else { throw LockScreenFailure("場景載入失敗，未替換鎖定背景") }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw LockScreenFailure("無法建立場景錄製器") }
        let width = 1920, height = max(2, Int((1920 * scene.size.height / scene.size.width) / 2) * 2)
        guard height <= 3840 else { throw LockScreenFailure("場景比例不適合鎖定影片") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw LockScreenFailure("無法建立錄製畫面") }
        // Aerial fills the display by cropping the movie. Move only the audio
        // overlays into that visible area, just as the desktop renderer does.
        let visibleAspect = aspect ?? scene.size.width / scene.size.height
        let visibleWidth = min(scene.size.width, scene.size.height * visibleAspect)
        let visibleHeight = min(scene.size.height, scene.size.width / visibleAspect)
        let visibleRect = CGRect(x: (scene.size.width - visibleWidth) / 2,
                                 y: (scene.size.height - visibleHeight) / 2,
                                 width: visibleWidth, height: visibleHeight)
        let renderer = SKRenderer(device: device); renderer.scene = scene
        scene.isPaused = false
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LockScreenFailure("無法寫入場景影片") }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        // Allow embedded AVPlayers to decode their first frame before recording.
        try pause(1, cancellation: cancellation)
        let start = CACurrentMediaTime()
        for frame in 0..<450 {
            try cancellation.check()
            let deadline = CACurrentMediaTime() + 15
            while !input.isReadyForMoreMediaData {
                try cancellation.check()
                guard writer.status == .writing, CACurrentMediaTime() < deadline else { throw writer.error ?? LockScreenFailure("場景錄製逾時") }
                try pause(0.005, cancellation: cancellation)
            }
            try autoreleasepool {
                renderer.update(atTime: CACurrentMediaTime())
                scene.layoutAudioOverlays(in: visibleRect)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                guard let command = queue.makeCommandBuffer() else { throw LockScreenFailure("無法繪製場景") }
                renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height), commandBuffer: command, renderPassDescriptor: pass)
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed else { throw LockScreenFailure("場景 GPU 錄製失敗") }
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw LockScreenFailure("無法配置影片影格") }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                texture.getBytes(CVPixelBufferGetBaseAddress(buffer)!, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? LockScreenFailure("場景影格寫入失敗") }
            }
            if (frame + 1) % 15 == 0 { progress(Double(frame + 1) / 450) }
            let delay = start + Double(frame + 1) / 30 - CACurrentMediaTime()
            if delay > 0 { try pause(delay, cancellation: cancellation) }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        while finished.wait(timeout: .now() + 0.05) == .timedOut { try cancellation.check() }
        try cancellation.check()
        guard writer.status == .completed else { throw writer.error ?? LockScreenFailure("場景影片未完成") }
        if !fm.fileExists(atPath: result.path) { try fm.moveItem(at: temporary, to: result) }
        return result
    }
    private static func pause(_ seconds: Double, cancellation: LockScreenCancellation) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try cancellation.check()
            Thread.sleep(forTimeInterval: min(0.02, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
    }

}
