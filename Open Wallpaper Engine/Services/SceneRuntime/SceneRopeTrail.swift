import SpriteKit

/// Bounded world-space particle chain for WE's cursor control point + rope renderer.
final class SceneRopeTrail: SKNode {
    private struct Particle { var point: CGPoint; var velocity: CGVector; var age: Double; let life: Double }
    private var particles: [Particle] = []
    private var remainder = 0.0
    private var previous: CGPoint?
    private let rate: Double
    private let limit: Int
    private let life: ClosedRange<Double>
    private let velocityX: ClosedRange<Double>
    private let velocityY: ClosedRange<Double>
    private let width: Double
    private let color: NSColor
    private let line = SKShapeNode()
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
        let rgb = vector(initializers.first { $0["name"] as? String == "colorrandom" }?["max"])
        color = rgb.count >= 3 ? NSColor(red: rgb[0]/255, green: rgb[1]/255, blue: rgb[2]/255, alpha: 1) : .white
        super.init()
        line.strokeColor = .clear; line.fillColor = color
        line.glowWidth = 2; line.blendMode = .add
        addChild(line)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(delta: Double, cursor: CGPoint?, enabled: Bool) {
        let dt = min(0.1, max(0, delta))
        for i in particles.indices {
            particles[i].age += dt
            particles[i].velocity.dx *= exp(-drag * dt)
            particles[i].velocity.dy *= exp(-drag * dt)
            particles[i].point.x += particles[i].velocity.dx * dt
            particles[i].point.y += particles[i].velocity.dy * dt
        }
        particles.removeAll { $0.age >= $0.life }
        if enabled, let cursor {
            remainder += dt * rate
            let births = Int(remainder); remainder -= Double(births)
            let start = previous ?? cursor
            for i in 0..<min(births, limit) {
                let t = Double(i + 1) / Double(max(1, births))
                let angle = Double.random(in: 0...(2 * .pi)), offset = Double.random(in: 0...radius)
                let p = CGPoint(x: start.x + (cursor.x-start.x)*t + cos(angle)*offset, y: start.y+(cursor.y-start.y)*t + sin(angle)*offset)
                particles.append(Particle(point: p, velocity: CGVector(dx: Double.random(in: velocityX), dy: Double.random(in: velocityY)), age: 0, life: Double.random(in: life)))
            }
            previous = cursor
        } else { previous = nil; remainder = 0 }
        if particles.count > limit { particles.removeFirst(particles.count-limit) }
        let path = CGMutablePath()
        func halfWidth(_ p: Particle) -> Double {
            let t = min(1, p.age / p.life / sizeEndTime)
            return max(0, width * (startSize + (endSize-startSize)*t) * 0.5)
        }
        for (a,b) in zip(particles, particles.dropFirst()) {
            let dx = b.point.x-a.point.x, dy = b.point.y-a.point.y
            let length = hypot(dx,dy)
            guard length > 0.001 else { continue }
            let nx = -dy/length, ny = dx/length, wa = halfWidth(a), wb = halfWidth(b)
            path.move(to: CGPoint(x:a.point.x+nx*wa,y:a.point.y+ny*wa))
            path.addLine(to: CGPoint(x:b.point.x+nx*wb,y:b.point.y+ny*wb))
            path.addLine(to: CGPoint(x:b.point.x-nx*wb,y:b.point.y-ny*wb))
            path.addLine(to: CGPoint(x:a.point.x-nx*wa,y:a.point.y-ny*wa))
            path.closeSubpath()
        }
        line.path = path
    }
}
