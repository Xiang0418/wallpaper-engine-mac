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

@main struct SceneCompatibilityTests {
    static func u32(_ value: UInt32, _ data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    static func makeTexture(version: Int = 3, compressed: Bool = true, format: UInt32 = 0, animated: Bool = true) -> Data {
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        let side: UInt32 = format == 4 ? 4 : 2
        for value: UInt32 in [format, animated ? 4 : 0, side, 1, side, 1, 0] { u32(value, &data) }
        data.append(Data("TEXB0004\0".utf8))
        for value: UInt32 in [2, UInt32.max, 0] { u32(value, &data) }
        for image in 0..<2 {
            u32(2, &data) // two mipmaps; metadata must be read after both atlases
            for _ in 0..<2 {
                let rgba: [UInt8] = image == 0 ? [255,0,0,255,0,255,0,255] : [0,0,255,255,255,255,255,255]
                let raw: [UInt8] = format == 4 ? [255,0,0,0,0,0,0,0,0,248,0,0,0,0,0,0] : rgba
                let payload: [UInt8] = compressed ? (raw.count < 15 ? [UInt8(raw.count << 4)] : [0xf0, UInt8(raw.count-15)]) + raw : raw
                for value: UInt32 in [side, format == 4 ? 4 : 1, compressed ? 1 : 0, UInt32(raw.count), UInt32(payload.count)] { u32(value, &data) }
                data.append(contentsOf: payload)
            }
        }
        guard animated else { return data }
        data.append(Data((String(format: "TEXS%04d", version) + "\0").utf8)); u32(2, &data)
        if version == 3 { u32(1, &data); u32(1, &data) }
        for index in 0..<2 {
            u32(UInt32(index), &data); u32(Float(index == 0 ? 0.05 : 0.15).bitPattern, &data)
            for value: Float in [Float(index), 0, 1, 0, 0, 1] { u32(version == 1 ? UInt32(value) : value.bitPattern, &data) }
        }
        return data
    }
    static func main() throws {
        _ = NSApplication.shared
        for version in 1...3 {
            for compressed in [false, true] {
                let data = makeTexture(version: version, compressed: compressed)
                guard let animation = TEXParser(data: data).extractAnimation() else { fatalError("TEXS version \(version), compressed \(compressed) failed") }
                precondition(animation.images.count == 2 && animation.frames.count == 2)
                precondition(animation.frames[1].imageIndex == 1 && animation.frames[1].rect.minX == 0.5)
                precondition(abs(animation.frames[1].duration - 0.15) < 0.00001)
                for length in 0..<data.count {
                    precondition(TEXParser(data: Data(data.prefix(length))).extractAnimation() == nil)
                }
            }
        }
        precondition(TEXParser(data: makeTexture(format: 4)).extractAnimation() != nil, "Animated BC3 keeps software decoder")
        precondition(TEXParser(data: makeTexture(animated: false)).extractAnimation() == nil, "Static texture path is unaffected")
        var invalid = makeTexture(); invalid.replaceSubrange((invalid.count-24)..<(invalid.count-20), with: [0,0,192,127])
        precondition(TEXParser(data: invalid).extractAnimation() == nil, "Reject nonfinite frame coordinates")
        var pkg = Data(); let name = Data("asset.tex".utf8)
        u32(8, &pkg); pkg.append(Data("PKGV0013".utf8)); u32(1, &pkg)
        u32(UInt32(name.count), &pkg); pkg.append(name); u32(0, &pkg); u32(3, &pkg); pkg.append(contentsOf: [1,2,3])
        let extracted = try PKGParser(data: pkg).extractFile(named: "asset.tex")!
        precondition(extracted.startIndex == 0 && extracted[0] == 1, "PKG entries have zero-based indices")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("we-compat-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for folder in ["materials", "models"] { try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true) }
        func json(_ value: Any, _ path: String) throws { try JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent(path)) }
        try makeTexture().write(to: directory.appendingPathComponent("materials/atlas.tex"))
        try makeTexture(animated: false).write(to: directory.appendingPathComponent("materials/static.tex"))
        for name in ["atlas", "static"] {
            try json(["material": "materials/\(name).json"], "models/\(name).json")
            try json(["passes": [["textures": [name], "blending": "translucent"]]], "materials/\(name).json")
        }
        try json(["camera": [:], "general": ["orthogonalprojection": ["width": 128, "height": 128]],
                  "objects": [
                    ["id": 3, "image": "models/atlas.json", "origin": "-1000 -1000 0"],
                    ["id": 1, "image": "models/atlas.json", "origin": "64 64 0", "size": "128 128"],
                    ["id": 2, "image": "models/static.json", "origin": "64 64 0", "size": "128 128", "effects": [
                        ["file": "effects/opacity/effect.json", "passes": [["constantshadervalues": ["alpha": 0.5]]]],
                        ["file": "effects/scroll/effect.json", "passes": [["constantshadervalues": ["speedx": ["value": -1, "user": "flow"], "speedy": 0, "repeat": "1 1"]]]]
                    ]]
                  ]], "scene.json")
        let model = SceneWallpaperViewModel(wallpaper: WEWallpaper(project: .init(file: "scene.json", title: "Compatibility"), wallpaperDirectory: directory))
        defer { model.stop() }
        let scene = model.skScene as! InteractiveWallpaperScene
        let animated = scene.childNode(withName: "//layer:1")!.children.first as! SKSpriteNode
        let scrolled = scene.childNode(withName: "//layer:2")!.children.first as! SKSpriteNode
        precondition((scene.childNode(withName: "//layer:3")!.children.first as! SKSpriteNode).size == CGSize(width: 1, height: 1), "Authored frame size is independent of Retina backing scale")
        precondition(model.renderingWarnings.isEmpty)
        scene.isPaused = false
        scene.update(0)
        let first = animated.texture
        scene.update(0.08)
        precondition(animated.texture !== first, "Unequal-duration animation advances through second atlas")
        let time = scrolled.shader!.uniformNamed("u_scrollTime")!.floatValue
        precondition(abs(time-0.08) < 0.0001)
        scene.isPaused = true; scene.update(1)
        precondition(scrolled.shader!.uniformNamed("u_scrollTime")!.floatValue == time && animated.texture !== first)
        scene.isPaused = false; scene.update(2)
        precondition(scrolled.shader!.uniformNamed("u_scrollTime")!.floatValue == time, "Wake cannot jump Scroll time")
        scene.update(2.08); scene.update(2.13)
        precondition(animated.texture === first, "Animation loops using total authored duration")
        scene.isPaused = true

        let view = SKView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; view.presentScene(scene)
        func pixels(at time: Float) -> Data {
            scrolled.shader!.uniformNamed("u_scrollTime")!.floatValue = time
            return view.texture(from: scrolled, crop: CGRect(x: -64, y: -64, width: 128, height: 128))!.cgImage().dataProvider!.data! as Data
        }
        let before = pixels(at: 0), after = pixels(at: 0.25)
        precondition(before != after, "Scroll changes GPU pixels while retaining opacity pipeline")
        let captured = view.texture(from: scrolled, crop: CGRect(x: -64, y: -64, width: 128, height: 128))!.cgImage()
        let bitmap = NSBitmapImageRep(cgImage: captured)
        let alpha = bitmap.colorAt(x: bitmap.pixelsWide/2, y: bitmap.pixelsHigh/2)!.alphaComponent
        precondition(alpha > 0.45 && alpha < 0.55, "Scroll preserves preceding opacity")
        scene.scriptRuntime?.applyUserProperties(["flow": 0])
        precondition(pixels(at: 0.25) == before, "Live user property can stop Scroll without replacing the shader")
        func frameColor() -> NSColor {
            let cg = view.texture(from: animated, crop: CGRect(x: -64, y: -64, width: 128, height: 128))!.cgImage()
            let rep = NSBitmapImageRep(cgImage: cg)
            return rep.colorAt(x: rep.pixelsWide/2, y: rep.pixelsHigh/2)!.usingColorSpace(.deviceRGB)!
        }
        let red = frameColor()
        scene.isPaused = false; scene.update(10); scene.update(10.08); scene.isPaused = true
        let white = frameColor()
        precondition(red.redComponent > 0.9 && red.greenComponent < 0.1 && white.greenComponent > 0.9 && white.blueComponent > 0.9,
                     "GPU animation crops the correct frame from each atlas")
        print("PKG, TEXS v1/v2/v3, LZ4/BC3 atlases, frame timing, pause/wake and Scroll GPU composition: passed")
    }
}
