// Standalone integration harness; compile with the production scene sources.
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
    func volumePublisher(for wallpaper: WEWallpaper) -> AnyPublisher<Float, Never> {
        $playVolume.eraseToAnyPublisher()
    }
}
final class AppDelegate {
    static let shared = AppDelegate()
    let wallpaperViewModel = PlaybackSettings()
}

@main struct SceneRenderingTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }; print("PASS: " + message)
    }
    static func main() throws {
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let parser = try PKGParser(url: fixture.appendingPathComponent("scene.pkg"))
        let textures = parser.fileList.filter { $0.hasSuffix(".tex") }
        var decoded = 0
        for path in textures {
            let tex = TEXParser(data: parser.extractFile(named: path)!)
            if tex.extractVideoData() != nil { continue }
            guard let image = tex.extractImage() else { fatalError("Texture failed: " + path) }
            decoded += 1
            let output = URL(fileURLWithPath: "/tmp/we-phase2-" + URL(fileURLWithPath: path).lastPathComponent + ".png")
            try tex.extractImageData()!.write(to: output)
            check(image.size.width > 0, "Texture " + path + " decoded: " + String(describing: image.size))
        }
        check(decoded == 7, "All seven static textures decode")
        let raw = Data(parser.extractFile(named: "materials/workshop/3573886911/default_dock_icon.tex")!)
        for length in 0..<min(100, raw.count) {
            check(TEXParser(data: Data(raw.prefix(length))).extractImage() == nil, "Reject truncated TEX at \(length)")
        }
        let bound = try WEScene.decode(data: Data(#"{"camera":{},"general":{},"objects":[{"visible":{"user":"show","value":true},"scale":{"user":"scale","value":"2 2 1"}}]}"#.utf8), projectData: Data(#"{"general":{"properties":{"show":{"value":false},"scale":{"value":3}}}}"#.utf8))
        check(bound.objects[0].visible == false && bound.objects[0].scale == "2 2 1", "Defaults resolve direct bindings without corrupting vectors")

        check(TEXParser.decodeLZ4([0x10,65,1,0], size: 5) == [65,65,65,65,65], "LZ4 overlapping match")
        check(TEXParser.decodeLZ4([0,0,0], size: 4) == nil, "LZ4 rejects zero offset")
        check(TEXParser.decodeLZ4([0xf0], size: 4) == nil, "LZ4 rejects truncated length")
        let bc3: [UInt8] = [255,0,0,0,0,0,0,0,0,248,0,0,0,0,0,0]
        let pixels = TEXParser.decodeBC(bc3, width: 4, height: 4, format: 4)!
        check(Array(pixels.prefix(4)) == [255,0,0,255] && pixels.count == 64, "BC3 red endpoint and alpha")
        check(TEXParser.decodeBC(Array(bc3.dropLast()), width: 4, height: 4, format: 4) == nil, "BC3 rejects truncated blocks")
        let wallpaper = WEWallpaper(project: .init(file: "scene.json", title: "Rendering"), wallpaperDirectory: fixture)
        let model = SceneWallpaperViewModel(wallpaper: wallpaper)
        let scene = model.skScene!
        func layer(_ id: Int) -> SKNode { scene.childNode(withName: "//layer:" + String(id))! }
        let decodedScene = try parser.extractJSON(named: "scene.json", as: WEScene.self)!
        let children = decodedScene.objects.filter { $0.parent != nil }
        check(children.count == 30 && children.allSatisfy { layer($0.id!).parent === layer($0.parent!) }, "All 30 parent relationships preserved")
        check(layer(529).parent === layer(509), "Cover has correct parent")
        check(layer(546).parent === layer(545), "Clock has correct parent")
        let origin = layer(546).convert(.zero, to: scene)
        check(abs(origin.x - (996.69373 - 30.29913 * 2.24843)) < 0.01, "Parent scale transforms child origin")
        check(layer(146).isHidden && layer(155).parent === layer(146), "Hidden dock retains launcher children")
        check(scene.descendants.compactMap { $0 as? SKLabelNode }.filter { $0.attributedText != nil }.count == 3, "Three clock labels load packaged fonts")
        let fonts = scene.descendants.compactMap { ($0 as? SKLabelNode)?.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }
        check(Set(fonts.map { $0.fontName }).count == 2, "Both distinct packaged fonts are used")

        check(abs(layer(425).xScale - 1.2) < 0.0001 && (layer(425).children.first as? SKSpriteNode)?.blendMode == .add, "Flare scale and additive blending")
        check(layer(529).children.first is SKSpriteNode && (layer(529).children.first as? SKSpriteNode)?.shader != nil, "Cover mask shader is attached")
        check(model.renderingWarnings.count == 1, "No missing materials, effects, textures or fonts")
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        view.ignoresSiblingOrder = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.presentScene(scene)
        AppDelegate.shared.wallpaperViewModel.playRate = 1
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        // Render static layers over the preview for repeatable visual QA.
        AppDelegate.shared.wallpaperViewModel.playRate = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        scene.descendants.compactMap { $0 as? SKVideoNode }.forEach { $0.isHidden = true }
        if let preview = scene.children.first(where: { $0.zPosition == 1_000_000 }) as? SKSpriteNode { preview.isHidden = false; preview.zPosition = -1 }
        guard let texture = view.texture(from: scene), let cg = texture.cgImage() as CGImage? else { fatalError("Render failed") }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/we-phase2-scene.png"))
        check(bitmap.pixelsWide == 1920, "Scene renders to image")
        let cover = layer(529).children.first as! SKSpriteNode
        if let isolated = view.texture(from: cover, crop: CGRect(x: -150, y: -150, width: 300, height: 300)) {
            let pixels = NSBitmapImageRep(cgImage: isolated.cgImage())
            let center = pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)!.alphaComponent
            let corner = pixels.colorAt(x: 0, y: 0)!.alphaComponent
            check(center > 0.9 && corner < 0.1, "GPU cover mask preserves center and removes corners")
        } else { fatalError("Cannot render cover mask") }

        // Force dock layers visible solely in this test to compile and inspect frame effects.
        layer(146).isHidden = false; layer(147).isHidden = false; layer(151).isHidden = false
        if let texture = view.texture(from: scene) {
            try NSBitmapImageRep(cgImage: texture.cgImage()).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/we-phase2-dock.png"))
        }
        model.stop()
        print("All phase-two rendering checks passed")
    }
}
extension SKNode { var descendants: [SKNode] { children.flatMap { [$0] + $0.descendants } } }
