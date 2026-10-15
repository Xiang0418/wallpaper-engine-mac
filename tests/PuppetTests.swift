import AVFoundation
import AppKit
import Combine
import SpriteKit
import simd

struct WEWallpaper {
  struct Project {
    var file: String
    var title: String?
  }
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

@main struct PuppetTests {
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      fputs("FAIL: \(message)\n", stderr)
      exit(1)
    }
  }
  static func main() throws {
    _ = NSApplication.shared
    let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
    let pkg = try PKGParser(url: fixture.appendingPathComponent("scene.pkg"))
    let raw =
      try JSONSerialization.jsonObject(with: pkg.extractFile(named: "scene.json")!)
      as! [String: Any]
    let objects = raw["objects"] as! [[String: Any]]
    var models: [Int: PuppetModel] = [:]
    for (id, name, bones, clips) in [
      (316, "波奇部件", 24, 3), (334, "鸭 部件", 23, 2), (398, "鼠标指针", 5, 1),
    ] {
      let data = pkg.extractFile(named: "models/\(name)_puppet.mdl")!
      let m = try MDLParser.parse(data)
      models[id] = m
      require(m.bones.count == bones && m.clips.count == clips, "Real skeleton/clip counts")
      let rest = m.deform(m.bones.map(\.bind))
      require(
        zip(rest, m.vertices).allSatisfy { simd_distance($0.0, $0.1.position) < 0.01 },
        "Bind skinning is identity")
      for clip in m.clips {
        let atZero = clip.sample(0).map(\.matrix)
        let atEnd = clip.sample(Double(clip.frames) / Double(clip.fps)).map(\.matrix)
        require(atZero == atEnd, "Loop wraps exactly")
        require(clip.sample(0.37).count == bones, "All bone tracks present")
      }
      for cut in [0, 8, 21, data.count / 3, data.count / 2, data.count - 100] {
        require(
          (try? MDLParser.parse(Data(data.prefix(cut)))) == nil, "Reject truncated model at \(cut)")
      }
      var invalid = data
      invalid[4] = 48
      invalid[7] = 57
      require((try? MDLParser.parse(invalid)) == nil, "Reject unsupported version")
      let meshStart = data[21...].firstIndex(of: 0)! + 1 + 28
      invalid = data
      invalid.replaceSubrange(meshStart + 4..<meshStart + 8, with: [255, 255, 255, 255])
      require((try? MDLParser.parse(invalid)) == nil, "Reject huge vertex buffer")
      invalid = data
      invalid.replaceSubrange(meshStart + 8..<meshStart + 12, with: [0, 0, 192, 127])
      require((try? MDLParser.parse(invalid)) == nil, "Reject NaN vertex")
    }
    // Numeric hierarchy test independent of the renderer and fixture animation.
    let identity = matrix_identity_float4x4
    var parent = identity
    parent.columns.3 = SIMD4(10, 20, 0, 1)
    var child = identity
    child.columns.3 = SIMD4(3, 4, 0, 1)
    let hierarchy = [
      PuppetModel.Bone(parent: 1, bind: child), PuppetModel.Bone(parent: nil, bind: parent),
    ]
    let worlds = try PuppetModel.world([child, parent], bones: hierarchy)
    require(worlds[0].columns.3 == SIMD4(13, 24, 0, 1), "Resolve parents out of order")
    require(
      (try? PuppetModel.world(
        [identity, identity],
        bones: [.init(parent: 1, bind: identity), .init(parent: 0, bind: identity)])) == nil,
      "Reject cyclic skeleton")
    let model = models[316]!
    let image = TEXParser(data: pkg.extractFile(named: "materials/波奇部件.tex")!).extractImage()!
    let size = CGSize(width: 2813, height: 2142)
    let node = ScenePuppetNode(
      model: model, image: image, size: size, layers: [["id": 1, "animation": 324, "blend": 0.0]])
    let rest = node.positions
    node.advance(0.1)
    require(
      zip(rest, node.positions).allSatisfy { simd_distance($0, $1) < 0.001 },
      "Zero blend preserves bind pose")
    node.applyAnimationLayers([["id": 1, "animation": 324, "blend": 1.0, "rate": 0.0]])
    node.advance(0)
    let held = node.positions
    node.advance(0.1)
    require(node.positions == held, "Zero rate holds phase")
    node.applyAnimationLayers([["id": 1, "animation": 324, "blend": 1.0, "rate": 1.0]])
    for _ in 0..<10 { node.advance(0.1) }
    require(
      zip(held, node.positions).contains { simd_distance($0, $1) > 1 },
      "Animation actually deforms mesh")
    node.applyAnimationLayers([
      ["id": 1, "animation": 324, "blend": 1.0, "rate": 1.0, "paused": true]
    ])
    let paused = node.positions
    node.advance(0.1)
    require(node.positions == paused, "Layer pause holds phase")
    // Test nested SceneScript rates against real audio buffers and layer control APIs.
    let object = objects.first { $0["id"] as? Int == 316 }!
    let holder = SKNode()
    holder.addChild(node)
    let runtime = SceneScriptRuntime(
      objects: [object], nodes: [316: holder], contentNodes: [316: node], properties: [:],
      size: CGSize(width: 3840, height: 2160), storageKey: "puppet-regression")
    runtime.setSpectrum(left: Array(repeating: 0, count: 64), right: Array(repeating: 0, count: 64))
    runtime.update(delta: 0.1, cursor: .zero)
    node.advance(0.1)
    let silent = node.positions
    runtime.setSpectrum(
      left: Array(repeating: 0.8, count: 64), right: Array(repeating: 0.8, count: 64))
    runtime.update(delta: 0.1, cursor: .zero)
    node.advance(0.1)
    require(
      zip(silent, node.positions).contains { simd_distance($0, $1) > 1 },
      "Audio scripts drive nested animation rate")
    require(runtime.diagnostics.isEmpty, "Puppet layer scripts run without exceptions")
    runtime.stop()
    let control: [String: Any] = [
      "id": 1, "animationlayers": [["id": 2, "name": "walk", "animation": 324]],
      "alpha": [
        "value": 1,
        "script":
          "export function init(){thisLayer.getAnimationLayer('walk').play();thisLayer.getAnimationLayer('walk').pause();}",
      ],
    ]
    let controlRuntime = SceneScriptRuntime(
      objects: [control], nodes: [1: SKNode()], properties: [:], size: size,
      storageKey: "puppet-controls")
    require(controlRuntime.diagnostics.isEmpty, "Animation play/pause API available during init")
    controlRuntime.stop()
    // Production loader, screenshot and playback lifecycle.
    AppDelegate.shared.wallpaperViewModel.playRate = 1
    let vm = SceneWallpaperViewModel(
      wallpaper: WEWallpaper(
        project: .init(file: "scene.json", title: "Puppet"), wallpaperDirectory: fixture))
    let scene = vm.skScene as! InteractiveWallpaperScene
    let view = SKView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    view.presentScene(scene)
    func puppet(_ id: Int) -> ScenePuppetNode {
      scene.childNode(withName: "//layer:\(id)")!.children.compactMap { $0 as? ScenePuppetNode }
        .first!
    }
    require(
      [316, 334, 398].allSatisfy { puppet($0).model.bones.count == models[$0]!.bones.count },
      "All puppets integrated")
    require(!vm.renderingWarnings.contains { $0.contains("puppet") }, "No Puppet fallback")
    // Hide the author's help overlay only in this ephemeral QA scene.
    scene.scriptRuntime!.applyUserProperties(["hrbigbpromptbox": false])
    scene.spectrumProvider = { Array(repeating: 0.15, count: 64) }
    scene.isPaused = false
    for i in 0...60 { scene.update(Double(i) / 60) }
    // SKView snapshots validate geometry only, not SK3DNode desktop orientation.
    func snapshot(_ suffix: String) throws {
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      let image = view.texture(from: scene)!.cgImage()
      try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: "/tmp/bocchi-puppet-\(suffix).png"))
    }
    try snapshot("frame1")
    let before = puppet(316).positions
    for i in 61...120 { scene.update(Double(i) / 60) }
    require(
      zip(before, puppet(316).positions).contains { simd_distance($0, $1) > 1 },
      "Production scene advances skeleton")
    try snapshot("frame2")
    vm.setPlaybackPolicy(paused: true, muted: true)
    let time = puppet(316).elapsed
    let points = puppet(316).positions
    scene.update(50)
    require(
      puppet(316).elapsed == time && puppet(316).positions == points,
      "Global pause freezes skeleton")
    scene.isPaused = false
    scene.update(100)
    require(puppet(316).elapsed == time, "Resume discards wall-clock gap")
    scene.update(100.016)
    require(puppet(316).elapsed > time, "Resume advances normally")
    let retained = puppet(316)
    vm.stop()
    let stopped = retained.elapsed
    scene.update(101)
    require(
      retained.elapsed == stopped && scene.children.isEmpty, "Stop releases scene and stops updates"
    )
    print(
      "PASS Puppet parser, hierarchy, interpolation, skinning, audio rates, controls, production rendering and lifecycle"
    )
  }
}
