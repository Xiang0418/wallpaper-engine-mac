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
final class AppDelegate {
    static let shared = AppDelegate()
    let wallpaperViewModel = PlaybackSettings()
}

@main struct SceneSpriteEffectsTests {
    static func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func main() throws {
        _ = NSApplication.shared
        let definition: [String: Any] = ["maxcount": 8, "emitter": [["name":"sphererandom", "rate":500]], "initializer": [["name":"lifetimerandom", "min":0.2, "max":0.2], ["name":"sizerandom", "min":10,"max":10]], "controlpoint":[["id":0,"flags":1]]]
        let system = SceneSpriteParticles(definition:definition, textures:[SKTexture(image:NSImage(size:CGSize(width:2,height:2)))], additive:false, overrides:[:])
        for _ in 0..<300 { system.advance(delta:1/60,cursor:CGPoint(x:30,y:40)); precondition(system.particleCount <= 8) }
        precondition(system.particleCount > 0)
        let holder = SKNode(); holder.addChild(system)
        let runtime = SceneScriptRuntime(objects:[["id":1,"instanceoverride":["size":["user":"particleSize","value":1]]]], nodes:[1:holder], properties:[:], size:CGSize(width:100,height:100), storageKey:"sprite-particle-test")
        runtime.applyUserProperties(["particleSize":2])
        system.advance(delta:1/60,cursor:CGPoint(x:30,y:40))
        precondition(system.children.compactMap { $0 as? SKSpriteNode }.allSatisfy { $0.size.width == 20 })
        for _ in 0..<30 { system.advance(delta:1/60,cursor:nil) }
        precondition(system.particleCount == 0, "Cursor departure stops emission and particles expire")
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = SceneWallpaperViewModel(wallpaper: WEWallpaper(project: .init(file: "scene.json", title: "Sprite effects"), wallpaperDirectory: fixture))
        defer { model.stop() }
        let scene = model.skScene as! InteractiveWallpaperScene
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:960,height:540), styleMask:[.titled], backing:.buffered, defer:false)
        let view = SKView(frame:window.contentView!.bounds)
        window.contentView = view; window.orderFront(nil); view.presentScene(scene)
        func sprite(_ id: Int) -> SKSpriteNode { scene.childNode(withName:"//layer:\(id)")!.children.compactMap { $0 as? SKSpriteNode }.first! }
        let poster = scene.childNode(withName:"//background-video-poster") as! SKSpriteNode
        precondition(poster.texture!.size().width >= 2560 && !poster.isHidden,
                     "Paused startup displays native-resolution video instead of 220px workshop preview")
        precondition(poster.parent === scene.childNode(withName:"//layer:65"), "Poster preserves background layer transform")
        let chibi = sprite(106)
        let video = chibi.userData?["videoTexture"] as! SceneVideoTexture
        precondition(video.player.rate == 0 && chibi.shader != nil)
        let style1 = sprite(87), style1Top = sprite(89), style3 = sprite(123)
        for selection in 1...4 {
            scene.scriptRuntime!.applyUserProperties(["newproperty1":String(selection)])
            for (id, expected) in [(87,1),(89,1),(72,2),(123,3)] {
                precondition(scene.childNode(withName:"//layer:\(id)")!.isHidden == (selection != expected), "Audio selection \(selection) layer \(id)")
            }
        }
        scene.scriptRuntime!.applyUserProperties(["newproperty1":"2"])
        scene.scriptRuntime!.applyUserProperties(["newproperty19":48,"newproperty20":0.25,"newproperty16":0.4,"amplitude":0.8,"sensitivity":0.7,"primarycolor":"0 1 0"])
        func parameter(_ node: SKSpriteNode, _ key: String) -> SKUniform {
            let binding = (node.userData?["effectBindings"] as! [[String:Any]]).first { $0["key"] as? String == key }!
            return node.shader!.uniformNamed(binding["name"] as! String)!
        }
        precondition(parameter(style1,"音频条数量").floatValue == 48 && abs(parameter(style1,"音频条间距").floatValue-0.25)<0.001)
        precondition(abs(parameter(style1Top,"音频条不透明度").floatValue-0.4)<0.001)
        precondition(abs(parameter(style3,"振幅").floatValue-0.8)<0.001 && abs(parameter(style3,"灵敏度").floatValue-0.7)<0.001)
        precondition(parameter(style3,"1 主色").vectorFloat3Value == SIMD3<Float>(0,1,0))
        scene.scriptRuntime!.applyUserProperties(["newproperty19":32,"newproperty20":0.1,"newproperty16":1,"amplitude":0.5,"sensitivity":1,"primarycolor":"1 0.45490 0.45490"])
        let bars = sprite(72)
        precondition(bars.shader?.uniformNamed("u_audioSpectrum") != nil)
        let particles = [113,134].map { scene.childNode(withName:"//layer:\($0)")!.children.compactMap { $0 as? SceneSpriteParticles }.first! }
        precondition(particles[0].particleCount > 0, "Fireflies prewarm")
        let ropeLayer = scene.childNode(withName:"//layer:23")!
        let petalsLayer = scene.childNode(withName:"//layer:134")!
        scene.scriptRuntime!.applyUserProperties(["wj":"1"])
        precondition(!ropeLayer.isHidden && petalsLayer.isHidden, "Style 1 selects rope only")
        scene.scriptRuntime!.applyUserProperties(["wj":"2"])
        precondition(ropeLayer.isHidden && !petalsLayer.isHidden, "Style 2 selects petals only")
        precondition(particles[1].zPosition > poster.zPosition, "Petals render above the opaque background")
        scene.scriptRuntime!.applyUserProperties(["wj":"3"])
        precondition(ropeLayer.isHidden && petalsLayer.isHidden, "Off disables both trails")
        scene.scriptRuntime!.applyUserProperties(["wj":"2"])
        AppDelegate.shared.wallpaperViewModel.playRate = 1
        // Drive the scene clock explicitly: a test window may be occluded and
        // SpriteKit can throttle its automatic display callbacks on macOS.
        for _ in 0..<150 { spin(0.02); scene.update(ProcessInfo.processInfo.systemUptime) }
        precondition(video.frameCount > 10, "Video overlay produces changing frames")
        for system in particles {
            for _ in 0..<120 { system.advance(delta:1/60,cursor:CGPoint(x:100,y:100)) }
            precondition(system.particleCount > 0 && system.particleCount <= 1000)
            precondition(system.children.contains { ($0 as? SKSpriteNode)?.texture != nil })
        }
        model.setPlaybackPolicy(paused:true,muted:false)
        let frames = video.frameCount, time = video.player.currentTime().seconds
        spin(0.3)
        precondition(video.frameCount == frames && abs(video.player.currentTime().seconds-time) < 0.05)
        model.setPlaybackPolicy(paused:false,muted:false)
        for _ in 0..<20 { spin(0.02); scene.update(ProcessInfo.processInfo.systemUptime) }
        precondition(video.frameCount > frames)
        let snapshot = view.texture(from: scene)!
        let bitmap = NSBitmapImageRep(cgImage:snapshot.cgImage())
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/we-sprite-effects.png"))
        // Render audio bars in isolation: silence must be transparent; signal must
        // fill lower bars with authored gaps instead of producing a solid rectangle.
        let isolated = SKScene(size:CGSize(width:320,height:160)); isolated.backgroundColor = .clear
        let copy = SKSpriteNode(texture:bars.texture); copy.shader = bars.shader; copy.size = isolated.size
        copy.position = CGPoint(x:160,y:80); isolated.addChild(copy)
        view.presentScene(isolated)
        func coverage(_ value: Float) -> Double {
            copy.shader!.uniformNamed("u_audioSpectrum")!.textureValue = SceneSpectrumTexture.texture(Array(repeating:value,count:64))
            spin(0.1)
            let bitmap = NSBitmapImageRep(cgImage:view.texture(from:isolated)!.cgImage())
            var count = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide { if bitmap.colorAt(x:x,y:y)!.alphaComponent > 0.2 { count += 1 } } }
            return Double(count) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        }
        let silent = coverage(0), loud = coverage(1)
        precondition(silent < 0.01 && loud > 0.1 && loud < 0.5, "Audio signal creates spaced bars; silence stays transparent: \(silent), \(loud)")
        for (index, original) in [(1,style1),(11,style1Top),(3,style3)] {
            copy.shader = original.shader
            precondition(copy.shader?.uniformNamed("u_audioSpectrum") != nil)
            let quiet = coverage(0)
            let quietData = NSBitmapImageRep(cgImage:view.texture(from:isolated)!.cgImage()).representation(using:.png,properties:[:])!
            let active = coverage(0.8)
            let activeData = NSBitmapImageRep(cgImage:view.texture(from:isolated)!.cgImage()).representation(using:.png,properties:[:])!
            precondition(active > 0.001 && active < 0.5, "Style \(index) renders an overlay, not an opaque framebuffer: \(active)")
            precondition(quietData != activeData, "Style \(index) responds to audio")
            if index != 3 { precondition(quiet < 0.01 && active > quiet + 0.01) }
            try activeData.write(to:URL(fileURLWithPath:"/tmp/we-audio-style-\(index).png"))
        }
        // presentScene stops the previous scene, releasing its overlay queue.
        precondition(video.player.items().isEmpty)
        let issues = SceneAssetDiagnostics.shared.reports.values.flatMap(\.issues)
        precondition(!issues.contains { $0.kind == .missing && $0.path.contains("_rt_") })
        precondition(!issues.contains { $0.kind == .invalid && $0.path.contains("恋死") })
        precondition(!issues.contains { $0.kind == .unsupported && ($0.path.contains("Simple_Audio_Bars") || $0.path.contains("particle renderer") || $0.path.contains("3444196917") || $0.path.contains("3782665413") || $0.path.contains("fisheye")) })
        for issue in issues { print("DIAGNOSTIC \(issue.kind): \(issue.path)") }
        window.orderOut(nil)
        print("PASS: real MP4 sprite frames, prewarmed fireflies, textured cherry particles, GPU audio bars, diagnostics and cleanup")
    }
}
