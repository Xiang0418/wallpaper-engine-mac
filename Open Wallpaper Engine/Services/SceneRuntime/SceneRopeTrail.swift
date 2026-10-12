import SpriteKit

/// Bounded world-space particle chain for WE's cursor control point + rope renderer.
final class SceneRopeTrail: SKNode {
    private struct Particle { var point: CGPoint; var velocity: CGVector; var age: Double; let life: Double }
    private var particles: [Particle] = []
    // Cursor history is sampled every frame, independently of particle births.
    private var path: [Particle] = []
    private(set) var renderedVertices: [CGPoint] = []
    private var remainder = 0.0
    private var previous: CGPoint?
    private let rate: Double
    private let limit: Int
    private let life: ClosedRange<Double>
    private let velocityX: ClosedRange<Double>
    private let velocityY: ClosedRange<Double>
    private let width: Double
    private let color: NSColor
    private var segments: [SKSpriteNode] = []
    private let beam = SceneRopeTrail.makeBeamTexture()
    private(set) var renderedTip: CGPoint?
    var segmentCount: Int { segments.filter { !$0.isHidden }.count }

    /// The size initializer describes the beam's full texture, not an opaque stroke.
    /// A narrow bright core replaces the unavailable engine beam texture.
    private static func makeBeamTexture() -> SKTexture {
        let height = 64
        var bytes = [UInt8](repeating: 0, count: height * 4)
        for y in 0..<height {
            let distance = (Double(y) + 0.5) / Double(height) * 2 - 1
            let alpha = min(1, exp(-pow(distance / 0.075, 2)) + 0.16 * exp(-pow(distance / 0.3, 2)))
            let value = UInt8(alpha * 255)
            for c in 0..<4 { bytes[y * 4 + c] = value }
        }
        let texture = SKTexture(data: Data(bytes), size: CGSize(width: 1, height: height))
        texture.filteringMode = .linear
        return texture
    }
    private let startSize: Double
    private let endSize: Double
    private let sizeEndTime: Double
    private let drag: Double
    private let radius: Double
    var particleCount: Int { particles.count }

    init(definition: [String: Any]) {
        let emitter = (definition["emitter"] as? [[String: Any]])?.first ?? [:]
        let operators = definition["operator"] as? [[String: Any]] ?? []
        let sizeChange = operators.first { $0["name"] as? String == "sizechange" } ?? [:]
        startSize = sizeChange["startvalue"] as? Double ?? 1
        endSize = sizeChange["endvalue"] as? Double ?? 0
        sizeEndTime = max(0.001, sizeChange["endtime"] as? Double ?? 1)
        drag = max(0, (operators.first { $0["name"] as? String == "movement" })?["drag"] as? Double ?? 0)
        radius = max(0, emitter["distancemax"] as? Double ?? 0)
        rate = min(1000, max(0, emitter["rate"] as? Double ?? 25))
        limit = min(4096, max(1, definition["maxcount"] as? Int ?? 500))
        let initializers = definition["initializer"] as? [[String: Any]] ?? []
        func pair(_ name: String, fallback: Double) -> ClosedRange<Double> {
            let item = initializers.first { $0["name"] as? String == name } ?? [:]
            let a = item["min"] as? Double ?? fallback, b = item["max"] as? Double ?? fallback
            return max(0.01, min(a,b))...max(0.01, max(a,b))
        }
        life = pair("lifetimerandom", fallback: 1)
        width = pair("sizerandom", fallback: 5).upperBound
        let velocity = initializers.first { $0["name"] as? String == "velocityrandom" } ?? [:]
        func vector(_ raw: Any?) -> [Double] { (raw as? String ?? "0 0 0").split(separator: " ").compactMap { Double($0) } }
        let low = vector(velocity["min"]), high = vector(velocity["max"])
        velocityX = min(low.first ?? 0, high.first ?? 0)...max(low.first ?? 0, high.first ?? 0)
        velocityY = min(low.count > 1 ? low[1] : 0, high.count > 1 ? high[1] : 0)...max(low.count > 1 ? low[1] : 0, high.count > 1 ? high[1] : 0)
        let rgb = vector(initializers.first { $0["name"] as? String == "colorrandom" }?["max"] ?? "255 255 255")
        color = rgb.count >= 3 ? NSColor(red: rgb[0]/255, green: rgb[1]/255, blue: rgb[2]/255, alpha: 1) : .white
        super.init()

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func disconnectCursor() { previous = nil; remainder = 0 }

    func update(delta: Double, cursor: CGPoint?, enabled: Bool, render: Bool = true) {
        let dt = min(0.1, max(0, delta))
        for i in particles.indices {
            particles[i].age += dt
            particles[i].velocity.dx *= exp(-drag * dt)
            particles[i].velocity.dy *= exp(-drag * dt)
            particles[i].point.x += particles[i].velocity.dx * dt
            particles[i].point.y += particles[i].velocity.dy * dt
        }
        particles.removeAll { $0.age >= $0.life }
        for i in path.indices {
            path[i].age += dt
            path[i].velocity.dx *= exp(-drag * dt)
            path[i].velocity.dy *= exp(-drag * dt)
            path[i].point.x += path[i].velocity.dx * dt
            path[i].point.y += path[i].velocity.dy * dt
        }
        path.removeAll { $0.age >= $0.life }
        if enabled, let cursor {
            if previous == nil { particles.removeAll(); path.removeAll() }
            let oldRemainder = remainder
            remainder += dt * rate
            let births = Int(remainder); remainder -= Double(births)
            let start = previous ?? cursor
            for i in 0..<min(births, limit) {
                let birthTime = rate > 0 ? (Double(i + 1) - oldRemainder) / rate : dt
                let t = dt > 0 ? min(1, max(0, birthTime / dt)) : 1
                let angle = Double.random(in: 0...(2 * .pi)), offset = Double.random(in: 0...radius)
                let p = CGPoint(x: start.x + (cursor.x-start.x)*t + cos(angle)*offset, y: start.y+(cursor.y-start.y)*t + sin(angle)*offset)
                particles.append(Particle(point: p, velocity: CGVector(dx: Double.random(in: velocityX), dy: Double.random(in: velocityY)), age: 0, life: Double.random(in: life)))
            }
            if rate > 0, path.last.map({ hypot($0.point.x-cursor.x, $0.point.y-cursor.y) > 0.25 }) ?? true {
                path.append(Particle(point: cursor, velocity: CGVector(dx: Double.random(in: velocityX), dy: Double.random(in: velocityY)), age: 0, life: Double.random(in: life)))
            }
            previous = cursor
        } else { disconnectCursor() }
        if particles.count > limit { particles.removeFirst(particles.count-limit) }
        // A live endpoint moves every rendered frame, independently of emission rate.
        if path.count > limit { path.removeFirst(path.count-limit) }
        guard render else { return }
        var points = path
        if enabled, let cursor {
            points.append(Particle(point: cursor, velocity: .zero, age: 0, life: life.upperBound))
            renderedTip = cursor
        } else { renderedTip = nil }
        var used = 0
        func halfWidth(_ p: Particle) -> Double {
            let t = min(1, p.age / p.life / sizeEndTime)
            return max(0, width * (startSize + (endSize-startSize)*t) * 0.5)
        }
        // Hermite interpolation shares tangents across samples. Clamp tangent
        // length at short spans so abrupt stops/reversals cannot create loops.
        var curve: [Particle] = []
        if let first = points.first { curve.append(first) }
        func tangent(_ before: CGPoint, _ after: CGPoint, span: Double) -> CGVector {
            let dx = (after.x-before.x)*0.5, dy = (after.y-before.y)*0.5
            let factor = min(1, span / max(0.001, hypot(dx,dy)))
            return CGVector(dx: dx*factor, dy: dy*factor)
        }
        for i in 0..<max(0, points.count-1) {
            let a = points[i], b = points[i+1]
            let length = hypot(b.point.x-a.point.x, b.point.y-a.point.y)
            guard length > 0.001 else { continue }
            let m0 = tangent(points[max(0,i-1)].point, b.point, span:length)
            let m1 = tangent(a.point, points[min(points.count-1,i+2)].point, span:length)
            let budget = max(1, 4096 / max(1, points.count-1))
            var steps = min(16, budget, max(1, Int(ceil(length / 6))))
            if steps > 1 {
                // Cubic-to-chord error <= max |P"| / (8 * steps²).
                // Keep error under 0.15 scene pixels where the original cap permits,
                // and retain subdivisions needed for the age-based width taper.
                let secondStart = hypot(-6*a.point.x - 4*m0.dx + 6*b.point.x - 2*m1.dx,
                                        -6*a.point.y - 4*m0.dy + 6*b.point.y - 2*m1.dy)
                let secondEnd = hypot(6*a.point.x + 2*m0.dx - 6*b.point.x + 4*m1.dx,
                                      6*a.point.y + 2*m0.dy - 6*b.point.y + 4*m1.dy)
                let curvatureSteps = max(1, Int(ceil(sqrt(max(secondStart, secondEnd) / 1.2))))
                let taperSteps = max(1, Int(ceil(abs(halfWidth(a)-halfWidth(b)) / 0.075)))
                steps = min(steps, max(curvatureSteps, taperSteps))
            }
            for step in 1...steps {
                let t = Double(step)/Double(steps), t2 = t*t, t3 = t2*t
                let h0 = 2*t3-3*t2+1, h1 = t3-2*t2+t, h2 = -2*t3+3*t2, h3 = t3-t2
                var sample = a
                sample.point = CGPoint(x:h0*a.point.x+h1*m0.dx+h2*b.point.x+h3*m1.dx,
                                       y:h0*a.point.y+h1*m0.dy+h2*b.point.y+h3*m1.dy)
                sample.age = a.age+(b.age-a.age)*t
                curve.append(sample)
            }
        }
        renderedVertices = curve.map(\.point)
        for (a,b) in zip(curve, curve.dropFirst()) {
            let dx = b.point.x-a.point.x, dy = b.point.y-a.point.y
            let length = hypot(dx,dy)
            let width = halfWidth(a) + halfWidth(b)
            guard length > 0.001, width > 0.01 else { continue }
            if used == segments.count {
                let segment = SKSpriteNode(texture: beam)
                segment.color = color; segment.colorBlendFactor = 1
                segment.blendMode = .add
                addChild(segment); segments.append(segment)
            }
            let segment = segments[used]
            segment.isHidden = false
            segment.position = CGPoint(x: (a.point.x+b.point.x)/2, y: (a.point.y+b.point.y)/2)
            segment.zRotation = atan2(dy,dx)
            segment.size = CGSize(width: length, height: width)
            used += 1
        }
        for i in used..<segments.count { segments[i].isHidden = true }
    }
}
