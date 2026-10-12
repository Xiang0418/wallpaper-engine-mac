import AppKit
import AVFoundation
import CoreImage
import SpriteKit

/// Video-backed image layers remain sprites so masks, tint and effects compose normally.
final class SceneVideoTexture {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private(set) var frameCount = 0
    private var lastTexture: SKTexture?
    let poster: NSImage

    init(url: URL) throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let image = try generator.copyCGImage(at: .zero, actualTime: nil)
        poster = NSImage(cgImage: image, size: .zero)
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func update(_ sprite: SKSpriteNode) {
        if let lastTexture { sprite.texture = lastTexture }
        guard let current = player.currentItem else { return }
        if item !== current {
            if let output { item?.remove(output) }
            let next = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            current.add(next); item = current; output = next
        }
        guard let output, output.hasNewPixelBuffer(forItemTime: current.currentTime()),
              let buffer = output.copyPixelBuffer(forItemTime: current.currentTime(), itemTimeForDisplay: nil) else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(ci, from: ci.extent) else { return }
        lastTexture = SKTexture(cgImage: image)
        sprite.texture = lastTexture
        frameCount += 1
    }

    func stop() {
        player.pause(); looper?.disableLooping()
        if let output { item?.remove(output) }
        output = nil; item = nil; player.removeAllItems(); looper = nil; lastTexture = nil
    }
    deinit { stop() }
}
