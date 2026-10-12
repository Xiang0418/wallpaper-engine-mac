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

@main struct SceneSharedAssetRenderingTests {
    static func main() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("shared-render-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("wallpaper"), shared = root.appendingPathComponent("assets")
        for directory in [local, shared.appendingPathComponent("models"), shared.appendingPathComponent("materials"), shared.appendingPathComponent("particles")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func json(_ value: Any, at url: URL) throws { try JSONSerialization.data(withJSONObject: value).write(to: url) }
        try json(["material": "materials/image.json"], at: shared.appendingPathComponent("models/image.json"))
        try json(["passes": [["textures": ["image"]]]], at: shared.appendingPathComponent("materials/image.json"))
        try json(["material": "materials/image.json", "emitter": [["rate": 3]], "renderer": [["name": "rope"]]], at: shared.appendingPathComponent("particles/shared.json"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<4 { for x in 0..<4 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        try bitmap.representation(using: .png, properties: [:])!.write(to: shared.appendingPathComponent("materials/image.png"))
        try json(["camera": [:], "general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": [
            ["id": 1, "image": "models/image.json", "size": "64 64", "origin": "32 32 0"],
            ["id": 2, "particle": "particles/shared.json", "origin": "32 32 0"]
        ]], at: local.appendingPathComponent("scene.json"))
        let wallpaper = WEWallpaper(project: .init(file: "scene.json", title: "Shared fixture"), wallpaperDirectory: local)
        var active: URL? = nil
        let model = SceneWallpaperViewModel(wallpaper: wallpaper, sharedAssets: { active })
        defer { model.stop() }
        precondition(SceneAssetDiagnostics.shared.reports.values.contains { $0.issues.contains { $0.kind == .missing && $0.path == "models/image.json" } })
        active = shared
        NotificationCenter.default.post(name: EngineAssetLibrary.didChange, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(model.skScene?.childNode(withName: "//layer:1")?.children.contains { $0 is SKSpriteNode } == true, "Shared model, material and texture build an image")
        precondition(model.skScene?.children.contains { $0 is SceneRopeTrail } == true, "Shared particle definition builds a supported rope")
        precondition(SceneAssetDiagnostics.shared.reports.values.allSatisfy { $0.issues.isEmpty }, "Reload clears resolved diagnostics; alternative extension probes stay silent")
        try Data("invalid JSON".utf8).write(to: shared.appendingPathComponent("models/image.json"))
        model.loadScene(from: wallpaper)
        precondition(SceneAssetDiagnostics.shared.reports.values.contains { $0.issues.contains { $0.kind == .invalid && $0.path == "models/image.json" } })
        model.stop()
        NotificationCenter.default.post(name: EngineAssetLibrary.didChange, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(SceneAssetDiagnostics.shared.reports.isEmpty, "Stopped sessions cannot reload or retain stale diagnostics")
        print("Shared scene integration: model/material/PNG/particles, reload, missing-vs-invalid diagnostics and stop lifecycle passed")
    }
}
