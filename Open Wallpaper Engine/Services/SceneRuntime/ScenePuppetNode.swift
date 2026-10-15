import SceneKit
import SpriteKit
import simd

/// A transparent SpriteKit content node whose child draws the indexed puppet mesh.
/// SceneKit supplies the triangle rasterizer; the scene's own clock drives skinning.
final class ScenePuppetNode: SKSpriteNode {
  let model: PuppetModel
  let viewport: SK3DNode
  private let mesh = SCNNode()
  private var parts: [SCNNode] = []
  private let uv: SCNGeometrySource
  private let elements: [SCNGeometryElement]
  private let material = SCNMaterial()
  private var hasGeometry = false
  private var layers: [[String: Any]]
  private var times: [Int: Double] = [:]
  private var revisions: [Int: Int] = [:]
  private(set) var positions: [SIMD3<Float>]
  private(set) var elapsed: Double = 0
  private var bindPoses: [PuppetModel.Pose]

  init(model: PuppetModel, image: NSImage, size: CGSize, layers: [[String: Any]]) {
    self.model = model
    self.layers = layers
    positions = model.vertices.map(\.position)
    bindPoses = model.bones.map { Self.pose($0.bind) }
    viewport = SK3DNode(viewportSize: size)
    // Keep MDL coordinates here. SK3DNode's on-screen Metal composition
    // flips its render target vertically. Negating vertex Y as well makes
    // desktop playback upside down. SKView.texture(from:) has a different
    // offscreen orientation and must not be used to calibrate this transform.
    uv = SCNGeometrySource(
      textureCoordinates: model.vertices.map { CGPoint(x: CGFloat($0.uv.x), y: CGFloat($0.uv.y)) })
    elements = (model.batches.isEmpty ? [0..<model.indices.count] : model.batches).map { range in
      SCNGeometryElement(indices: Array(model.indices[range]), primitiveType: .triangles)
    }
    super.init(texture: nil, color: .clear, size: size)
    material.diffuse.contents = image
    material.lightingModel = .constant
    material.isDoubleSided = true
    material.readsFromDepthBuffer = false
    material.writesToDepthBuffer = false
    material.diffuse.wrapS = .clamp
    material.diffuse.wrapT = .clamp
    material.blendMode = .alpha
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    scene.rootNode.addChildNode(mesh)
    // Separate nodes prevent SceneKit from sorting transparent elements
    // out of the authored batch order (hair must stay behind the sleeve).
    for i in elements.indices {
      let part = SCNNode()
      part.renderingOrder = i
      mesh.addChildNode(part)
      parts.append(part)
    }
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera!.usesOrthographicProjection = true
    camera.camera!.orthographicScale = Double(size.height) / 2
    camera.camera!.zNear = 0.1
    camera.camera!.zFar = 20000
    camera.position = SCNVector3(0, 0, 10000)
    scene.rootNode.addChildNode(camera)
    viewport.scnScene = scene
    viewport.pointOfView = camera
    viewport.autoenablesDefaultLighting = false
    viewport.isPlaying = false
    addChild(viewport)
    advance(0)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func applyAnimationLayers(_ values: [[String: Any]]) { layers = values }
  private static func pose(_ m: simd_float4x4) -> PuppetModel.Pose {
    var s = SIMD3(simd_length(m.columns.0), simd_length(m.columns.1), simd_length(m.columns.2))
    if simd_determinant(m) < 0 { s.x = -s.x }
    let r = simd_float3x3(
      SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z) / s.x,
      SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z) / s.y,
      SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) / s.z)
    return .init(
      translation: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), rotation: simd_quatf(r),
      scale: s)
  }
  private func number(_ value: Any?, default fallback: Double) -> Double {
    let resolved = (value as? [String: Any])?["value"] ?? value
    guard let n = resolved as? NSNumber, n.doubleValue.isFinite else { return fallback }
    return n.doubleValue
  }
  func advance(_ delta: Double) {
    let dt = max(0, min(0.1, delta))
    elapsed += dt
    var locals = bindPoses
    // Base layers compose first; additive clips apply deltas to the result.
    let ordered =
      layers.enumerated().filter { $0.element["additive"] as? Bool != true }
      + layers.enumerated().filter { $0.element["additive"] as? Bool == true }
    for (index, layer) in ordered {
      let key = layer["id"] as? Int ?? index
      guard let id = layer["animation"] as? Int,
        let clip = model.clips.first(where: { $0.id == id })
      else { continue }
      let revision = layer["restart"] as? Int ?? 0
      if revisions[key] != revision {
        times[key] = 0
        revisions[key] = revision
      }
      let active = number(layer["visible"], default: 1) != 0
      if !active { continue }
      if layer["paused"] as? Bool != true {
        let rate = min(1000, max(-1000, number(layer["rate"], default: 1)))
        let duration = Double(clip.frames) / Double(clip.fps)
        let next = times[key, default: 0] + dt * rate
        times[key] =
          clip.mode == "loop"
          ? (next.truncatingRemainder(dividingBy: duration) + duration).truncatingRemainder(
            dividingBy: duration) : min(duration, max(0, next))
      }
      let weight = Float(min(1, max(0, number(layer["blend"], default: 1))))
      let sample = clip.sample(times[key, default: 0])
      if layer["additive"] as? Bool == true {
        for i in locals.indices {
          let delta = Self.pose(simd_inverse(model.bones[i].bind) * sample[i].matrix)
          let identity = PuppetModel.Pose(
            translation: .zero, rotation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)),
            scale: SIMD3(repeating: 1))
          locals[i] = Self.pose(
            locals[i].matrix * identity.mixed(with: delta, weight: weight).matrix)
        }
      } else {
        for i in locals.indices { locals[i] = locals[i].mixed(with: sample[i], weight: weight) }
      }
    }
    let updated = model.deform(locals.map(\.matrix))
    guard !hasGeometry || updated != positions else { return }
    hasGeometry = true
    positions = updated
    let vertices = SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
    for i in elements.indices {
      let geometry = SCNGeometry(sources: [vertices, uv], elements: [elements[i]])
      geometry.materials = [material]
      parts[i].geometry = geometry
    }
  }
}
