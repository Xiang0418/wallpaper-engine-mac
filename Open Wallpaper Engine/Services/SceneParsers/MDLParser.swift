import Foundation
import simd

/// Bounded reader for the MDLV0023 2D puppet layout. Format reference:
/// https://github.com/wqLouis/pkg_parser/tree/crate/src/pkg_parser/mdl_parser
/// Animation IDs and the fixed clip trailer are verified against local exports.
struct PuppetModel {
  struct Vertex {
    let position: SIMD3<Float>
    let uv: SIMD2<Float>
    let bones: [Int]
    let weights: [Float]
  }
  struct Bone {
    let parent: Int?
    let bind: simd_float4x4
  }
  struct Pose {
    var translation: SIMD3<Float>
    var rotation: simd_quatf
    var scale: SIMD3<Float>
    var matrix: simd_float4x4 {
      var m = simd_float4x4(rotation)
      m.columns.0 *= scale.x
      m.columns.1 *= scale.y
      m.columns.2 *= scale.z
      m.columns.3 = SIMD4(translation, 1)
      return m
    }
    func mixed(with b: Pose, weight: Float) -> Pose {
      Pose(
        translation: translation + (b.translation - translation) * weight,
        rotation: simd_slerp(rotation, b.rotation, weight),
        scale: scale + (b.scale - scale) * weight)
    }
  }
  struct Clip {
    let id: Int
    let name: String
    let mode: String
    let fps: Float
    let frames: Int
    let tracks: [[Pose]]
    func sample(_ time: Double) -> [Pose] {
      guard time.isFinite else { return tracks.map { $0[0] } }
      let duration = Double(frames) / Double(fps)
      let t =
        mode == "loop"
        ? (time.truncatingRemainder(dividingBy: duration) + duration).truncatingRemainder(
          dividingBy: duration) : min(duration, max(0, time))
      let f = min(Float(frames), Float(t) * fps)
      let a = Int(f)
      let b = min(frames, a + 1)
      return tracks.map { $0[a].mixed(with: $0[b], weight: f - Float(a)) }
    }
  }
  let vertices: [Vertex]
  let indices: [UInt16]
  let batches: [Range<Int>]
  let bones: [Bone]
  let clips: [Clip]
  let inverseBind: [simd_float4x4]

  static func world(_ locals: [simd_float4x4], bones: [Bone]) throws -> [simd_float4x4] {
    guard locals.count == bones.count else { throw MDLParser.Failure.invalid("pose size") }
    var result = Array(repeating: matrix_identity_float4x4, count: bones.count)
    var done = Set<Int>()
    for _ in bones.indices {
      let before = done.count
      for i in bones.indices where !done.contains(i) {
        if let p = bones[i].parent {
          guard bones.indices.contains(p), p != i else {
            throw MDLParser.Failure.invalid("bone parent")
          }
          if !done.contains(p) { continue }
          result[i] = result[p] * locals[i]
        } else {
          result[i] = locals[i]
        }
        done.insert(i)
      }
      if done.count == bones.count { return result }
      if before == done.count { throw MDLParser.Failure.invalid("bone cycle") }
    }
    return result
  }

  func deform(_ locals: [simd_float4x4]) -> [SIMD3<Float>] {
    guard !bones.isEmpty, let world = try? Self.world(locals, bones: bones) else {
      return vertices.map(\.position)
    }
    let skin = world.indices.map { world[$0] * inverseBind[$0] }
    return vertices.map { v in
      var p = SIMD4<Float>.zero
      var total: Float = 0
      for i in 0..<4 where v.weights[i] > 0 {
        p += (skin[v.bones[i]] * SIMD4(v.position, 1)) * v.weights[i]
        total += v.weights[i]
      }
      return total > 0 ? SIMD3(p.x, p.y, p.z) / total : v.position
    }
  }
}

enum MDLParser {
  enum Failure: Error { case invalid(String) }
  private struct Reader {
    let bytes: [UInt8]
    var offset = 0
    var limit: Int
    init(_ data: Data) {
      bytes = Array(data)
      limit = data.count
    }
    mutating func skip(_ n: Int) throws {
      guard n >= 0, offset <= limit, n <= limit - offset else { throw Failure.invalid("truncated") }
      offset += n
    }
    mutating func u8() throws -> UInt8 {
      try skip(1)
      return bytes[offset - 1]
    }
    mutating func u16() throws -> UInt16 {
      let a = try u8()
      let b = try u8()
      return UInt16(a) | UInt16(b) << 8
    }
    mutating func u32() throws -> UInt32 {
      let a = try u16()
      let b = try u16()
      return UInt32(a) | UInt32(b) << 16
    }
    mutating func f() throws -> Float {
      let v = Float(bitPattern: try u32())
      guard v.isFinite, abs(v) <= 1e9 else { throw Failure.invalid("nonfinite") }
      return v
    }
    mutating func vec() throws -> SIMD3<Float> { try SIMD3(f(), f(), f()) }
    mutating func string() throws -> String {
      let start = offset
      while offset < limit, bytes[offset] != 0, offset - start < 16384 { offset += 1 }
      guard offset < limit, bytes[offset] == 0,
        let s = String(bytes: bytes[start..<offset], encoding: .utf8)
      else { throw Failure.invalid("string") }
      offset += 1
      return s
    }
    mutating func matrix() throws -> simd_float4x4 {
      var v: [Float] = []
      for _ in 0..<16 { v.append(try f()) }
      return simd_float4x4(
        SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
        SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
    }
  }
  static func parse(_ data: Data) throws -> PuppetModel {
    guard data.count <= 64 * 1024 * 1024 else { throw Failure.invalid("model size") }
    var r = Reader(data)
    guard try r.string() == "MDLV0023" else { throw Failure.invalid("unsupported MDLV version") }
    try r.skip(12)
    _ = try r.string()
    try r.skip(28)
    guard try r.u32() == 0x0180_000f else { throw Failure.invalid("vertex format") }
    let bytes = Int(try r.u32())
    guard bytes > 0, bytes % 80 == 0, bytes / 80 <= 65536, bytes <= r.limit - r.offset else {
      throw Failure.invalid("vertices")
    }
    var vertices: [PuppetModel.Vertex] = []
    for _ in 0..<bytes / 80 {
      let p = try r.vec()
      try r.skip(28)
      var bones: [Int] = []
      var weights: [Float] = []
      for _ in 0..<4 { bones.append(Int(try r.u32())) }
      for _ in 0..<4 {
        let w = try r.f()
        guard w >= 0 else { throw Failure.invalid("weight") }
        weights.append(w)
      }
      let uv = try SIMD2(r.f(), r.f())
      vertices.append(.init(position: p, uv: uv, bones: bones, weights: weights))
    }
    let indexBytes = Int(try r.u32())
    guard indexBytes > 0, indexBytes % 6 == 0, indexBytes <= r.limit - r.offset else {
      throw Failure.invalid("indices")
    }
    var indices: [UInt16] = []
    for _ in 0..<indexBytes / 2 {
      let i = try r.u16()
      guard Int(i) < vertices.count else { throw Failure.invalid("index range") }
      indices.append(i)
    }
    let extras = try r.u8()
    for _ in 0..<extras {
      _ = try r.u32()
      let n = Int(try r.u32())
      try r.skip(n)
    }
    guard try r.u8() == 1 else { throw Failure.invalid("batch tag") }
    let table = Int(try r.u32())
    guard table % 16 == 0, table <= r.limit - r.offset else { throw Failure.invalid("batches") }
    var batches: [Range<Int>] = []
    var nextIndex = 0
    for _ in 0..<table / 16 {
      _ = try r.u32()
      _ = try r.u32()
      let start = Int(try r.u32())
      let count = Int(try r.u32())
      guard start == nextIndex, start <= indices.count, count <= indices.count - start,
        count % 3 == 0
      else { throw Failure.invalid("batch range") }
      batches.append(start..<start + count)
      nextIndex = start + count
    }
    guard nextIndex == indices.count else { throw Failure.invalid("batch coverage") }
    _ = try r.u32()
    var bones: [PuppetModel.Bone] = []
    var clips: [PuppetModel.Clip] = []
    while r.offset < r.limit, r.bytes[r.offset] != 0 {
      let section = try r.string()
      let end = Int(try r.u32())
      guard end >= r.offset, end <= data.count else { throw Failure.invalid("section offset") }
      r.limit = end
      switch section {
      case "MDLS0004":
        let n = Int(try r.u32())
        guard n <= 512 else { throw Failure.invalid("bones") }
        _ = try r.u8()
        for _ in 0..<n {
          _ = try r.u32()
          let parent = try r.u32()
          guard try r.u32() == 64 else { throw Failure.invalid("bind matrix") }
          let m = try r.matrix()
          guard abs(simd_determinant(m)) > 1e-8 else { throw Failure.invalid("singular bind") }
          _ = try r.string()
          _ = try r.string()
          bones.append(.init(parent: parent == .max ? nil : Int(parent), bind: m))
        }
      case "MDLA0006":
        let n = Int(try r.u32())
        guard n <= 64 else { throw Failure.invalid("clip count") }
        for _ in 0..<n {
          let id = Int(try r.u32())
          _ = try r.u32()
          let name = try r.string()
          let mode = try r.string()
          let fps = try r.f()
          let frames = Int(try r.u32())
          _ = try r.u32()
          let count = Int(try r.u32())
          guard fps > 0, fps <= 1000, frames > 0, frames <= 100000, count == bones.count,
            !bones.isEmpty, ["loop", "single"].contains(mode)
          else { throw Failure.invalid("clip header") }
          var tracks: [[PuppetModel.Pose]] = []
          for _ in 0..<count {
            _ = try r.u32()
            let n = Int(try r.u32())
            guard n == (frames + 1) * 36, n <= r.limit - r.offset else {
              throw Failure.invalid("keyframes")
            }
            var poses: [PuppetModel.Pose] = []
            for _ in 0...frames {
              let t = try r.vec()
              let e = try r.vec()
              let s = try r.vec()
              let q =
                simd_quatf(angle: e.x, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: e.y, axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: e.z, axis: SIMD3(0, 0, 1))
              poses.append(.init(translation: t, rotation: q, scale: s))
            }
            tracks.append(poses)
          }
          // MDLA0006 exported 2D clips have a 35-byte empty morph trailer.
          for _ in 0..<35 {
            guard try r.u8() == 0 else { throw Failure.invalid("unsupported morph tracks") }
          }
          clips.append(
            .init(id: id, name: name, mode: mode, fps: fps, frames: frames, tracks: tracks))
        }
        guard r.offset == end else { throw Failure.invalid("animation end") }
      case "MDLE0002", "MDAT0001": break
      default: throw Failure.invalid("unsupported section \(section)")
      }
      r.offset = end
      r.limit = data.count
    }
    for v in vertices {
      for i in 0..<4 where v.weights[i] > 0 {
        guard bones.indices.contains(v.bones[i]) else { throw Failure.invalid("skin bone") }
      }
    }
    let world = try PuppetModel.world(bones.map(\.bind), bones: bones)
    return PuppetModel(
      vertices: vertices, indices: indices, batches: batches, bones: bones, clips: clips,
      inverseBind: world.map(simd_inverse))
  }
}
