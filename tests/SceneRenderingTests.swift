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
        for (id, expectedHeight) in [(546, 140.0), (547, 134.0), (548, 61.0)] {
            let label = layer(id).children.first as! SceneTextNode
            let font = label.attributedText!.attribute(.font, at:0, effectiveRange:nil) as! NSFont
            check(abs(font.ascender-font.descender-expectedHeight) < 1,
                  "Packaged text height matches font raster metrics for layer \(id)")
        }

        check(abs(layer(425).xScale - 1.2) < 0.0001 && (layer(425).children.first as? SKSpriteNode)?.blendMode == .add, "Flare scale and additive blending")
        check(layer(529).children.first is SKSpriteNode && (layer(529).children.first as? SKSpriteNode)?.shader != nil, "Cover mask shader is attached")
        check(model.renderingWarnings.isEmpty, "No missing materials, effects, textures or fonts")
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        view.ignoresSiblingOrder = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.presentScene(scene)
        AppDelegate.shared.wallpaperViewModel.playRate = 1
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        scene.isPaused = true
        for (id, digits) in [(546, "02"), (547, "55"), (548, "43")] {
            (layer(id).children.first as? SceneTextNode)?.updateText(digits)
        }
        if let live = view.texture(from: scene) {
            try NSBitmapImageRep(cgImage: live.cgImage()).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/we-live-layout.png"))
        }
        scene.isPaused = false
        // Render static layers over the preview for repeatable visual QA.
        AppDelegate.shared.wallpaperViewModel.playRate = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        scene.descendants.compactMap { $0 as? SKVideoNode }.forEach { $0.isHidden = true }
        if let preview = scene.children.first(where: { $0.zPosition == 1_000_000 }) as? SKSpriteNode { preview.isHidden = false; preview.zPosition = -1 }
        guard let texture = view.texture(from: scene), let cg = texture.cgImage() as CGImage? else { fatalError("Render failed") }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/we-phase2-scene.png"))
        check(bitmap.pixelsWide == 1920 || bitmap.pixelsWide == 3840, "Scene renders at display backing resolution")
        let cover = layer(529).children.first as! SKSpriteNode
        if let isolated = view.texture(from: cover, crop: CGRect(x: -150, y: -150, width: 300, height: 300)) {
            let pixels = NSBitmapImageRep(cgImage: isolated.cgImage())
            let center = pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)!.alphaComponent
            let corner = pixels.colorAt(x: 0, y: 0)!.alphaComponent
            check(center > 0.9 && corner < 0.1, "GPU cover mask preserves center and removes corners")
        } else { fatalError("Cannot render cover mask") }

        let interactive = scene as! InteractiveWallpaperScene
        let runtime = interactive.scriptRuntime!
        runtime.applyUserProperties(["appdockenabled":true,"appdockenable1":true,"appdockenable15":true])
        for _ in 0..<60 { runtime.update(delta:1.0/60,cursor:CGPoint(x:960,y:80)) }
        check(runtime.diagnostics.isEmpty,"Original scripts run against phase-two nodes without exceptions")
        check(!layer(146).isHidden && !layer(155).isHidden,"User properties enable the real dock containers")
        let clockText=(layer(548).children.first as! SKLabelNode).attributedText!.string
        check(clockText.count == 2 && Int(clockText) != nil,"Live seconds preserve attributed packaged font")
        let launcher=layer(155).children.first as! SKSpriteNode
        let originalIcon=launcher.texture
        runtime.applyUserProperties(["launcher1":fixture.appendingPathComponent("project.json").path])
        check(launcher.texture !== originalIcon,"Local shortcut uses the native macOS file/application icon")
        runtime.applyUserProperties(["launcher1":""])
        check(launcher.texture === originalIcon,"Clearing shortcut restores the package icon")
        let hit=launcher.convert(CGPoint(x:0,y:launcher.size.height*0.5),to:scene)
        var launches=0
        runtime.openShortcut={ _ in launches += 1 }
        runtime.applyUserProperties(["launcher1":"https://example.com"])
        runtime.mouseDown(at:hit);runtime.mouseUp(at:hit)
        check(launches == 1,"Actual transformed launcher dispatches one shortcut click")
        let previousY=layer(155).position.y
        for _ in 0..<5 { runtime.update(delta:1.0/60,cursor:hit) }
        check(layer(155).position.y != previousY,"Click starts original launcher bounce animation")
        let spectrum=layer(509).children.compactMap { $0 as? SKSpriteNode }.first!
        let shader=spectrum.shader!
        func spectrumPixels(_ value:Float) -> Data {
            shader.uniformNamed("u_audioSpectrum")!.textureValue=SceneSpectrumTexture.texture(Array(repeating:value,count:64))
            let texture=view.texture(from:spectrum,crop:CGRect(x:-100,y:-100,width:200,height:200))!
            return texture.cgImage().dataProvider!.data! as Data
        }
        check(spectrumPixels(0) != spectrumPixels(0.8),"Integrated spectrum shader pixels respond to frequency data")
        if let texture = view.texture(from: scene) {
            try NSBitmapImageRep(cgImage: texture.cgImage()).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/we-phase3-integrated.png"))
        }
        let trail = SceneRopeTrail(definition:["emitter":[["rate":25]],
            "initializer":[["name":"lifetimerandom","min":1,"max":1],["name":"sizerandom","min":5,"max":5]],
            "operator":[["name":"sizechange","startvalue":3.0,"endvalue":0.0,"endtime":0.5]]])
        trail.update(delta:0.04,cursor:CGPoint(x:20,y:100),enabled:true)
        trail.update(delta:0.04,cursor:CGPoint(x:300,y:100),enabled:true)
        let trailGroup = SKNode()
        let trailBackground = SKSpriteNode(color:.black,size:CGSize(width:400,height:200))
        trailBackground.anchorPoint = .zero
        trailBackground.zPosition = -1
        trailGroup.addChild(trailBackground); trailGroup.addChild(trail)
        scene.addChild(trailGroup)
        let trailTexture = view.texture(from:trailGroup)!
        let trailBitmap = NSBitmapImageRep(cgImage:trailTexture.cgImage())
        let profile = (0..<trailBitmap.pixelsHigh).map { trailBitmap.colorAt(x:150,y:$0)!.usingColorSpace(.deviceRGB)!.redComponent }
        let peak = profile.max() ?? 0
        let corePixels = profile.filter { $0 > peak * 0.5 }.count
        try trailBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/we-thin-trail.png"))
        check(peak > 0.1 && corePixels > 0 && corePixels <= 4,"GPU beam has a narrow luminous core, not a filled 15-pixel ribbon")
        model.stop()
        print("All phase-two rendering checks passed")
    }
}
extension SKNode { var descendants: [SKNode] { children.flatMap { [$0] + $0.descendants } } }
