import SpriteKit

/// Replace only the albedo texture. Authored shaders, masks, transforms and
/// visibility remain in the existing material pipeline.
final class SceneMediaArtworkBinding {
    private weak var sprite: SKSpriteNode?
    private let original: SKTexture?
    init(sprite: SKSpriteNode) { self.sprite = sprite; original = sprite.texture }

    func apply(_ texture: SKTexture?) {
        guard let sprite else { return }
        guard let texture else { sprite.texture = original; return }
        let source = texture.size(), target = sprite.size
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return }
        let sourceAspect = source.width / source.height, targetAspect = target.width / target.height
        let rect: CGRect
        if sourceAspect > targetAspect {
            let width = targetAspect / sourceAspect
            rect = CGRect(x: (1-width)/2, y: 0, width: width, height: 1)
        } else {
            let height = sourceAspect / targetAspect
            rect = CGRect(x: 0, y: (1-height)/2, width: 1, height: height)
        }
        sprite.texture = SKTexture(rect: rect, in: texture)
    }
}
