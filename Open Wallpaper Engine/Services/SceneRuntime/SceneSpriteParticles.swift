import SpriteKit

/// Bounded 2D implementation of sprite and short sprite-trail particle systems.
/// Motion operators approximate WE's 3D simulation; texture atlases remain authored assets.
final class SceneSpriteParticles: SKNode {
    struct Particle {
        let sprite: SKSpriteNode
        var position: SIMD2<Double>
        var velocity: SIMD2<Double>
        var age: Double = 0
        let lifetime: Double
        let size: Double
        let alpha: Double
        let phase: Double
        var children: [SceneSpriteParticles] = []
    }
    private let definition: [String: Any]
    private let textures: [SKTexture]
    private let additive: Bool
    private var overrides: [String: Any]
    private let childFactory: (() -> [SceneSpriteParticles])?
    private var particles: [Particle] = []
    private var remainder = 0.0
    private var randomState: UInt64 = 0x9e3779b97f4a7c15
    private(set) var elapsed = 0.0
    var particleCount: Int { particles.count }
    private var initializers: [[String: Any]] { definition["initializer"] as? [[String: Any]] ?? [] }
    private var operators: [[String: Any]] { definition["operator"] as? [[String: Any]] ?? [] }
    private var emitter: [String: Any] { (definition["emitter"] as? [[String: Any]])?.first ?? [:] }
    private var maximum: Int { Int(min(1000, max(0, Self.number(definition, "maxcount", 100)))) }
    static func number(_ d: [String: Any], _ key: String, _ fallback: Double) -> Double {
        let nested = d[key] as? [String: Any]
        let value = (d[key] as? NSNumber)?.doubleValue ?? (nested?["value"] as? NSNumber)?.doubleValue ?? (nested?["x"] as? NSNumber)?.doubleValue ?? fallback
        return value.isFinite ? value : fallback
    }
    private func vector(_ value: Any?, _ fallback: SIMD3<Double> = .zero) -> SIMD3<Double> {
        let raw = (value as? [String: Any])?["value"] ?? value
        guard let text = raw as? String else { return fallback }
        let v = text.split(separator: " ").compactMap { Double($0) }
        guard v.count >= 3, v.allSatisfy(\.isFinite) else { return fallback }
        return SIMD3(v[0], v[1], v[2])
    }
    init(definition: [String: Any], textures: [SKTexture], additive: Bool, overrides: [String: Any], children: (() -> [SceneSpriteParticles])? = nil) {
        self.definition = definition; self.textures = textures; self.additive = additive
        self.overrides = overrides; self.childFactory = children
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyOverrides(_ values: [String: Any]) { overrides = values }
    private func random() -> Double {
        randomState ^= randomState << 13; randomState ^= randomState >> 7; randomState ^= randomState << 17
        return Double(randomState >> 11) / Double(UInt64(1) << 53)
    }
    private func range(_ d: [String: Any], _ low: String, _ high: String, _ fallback: Double) -> Double {
        let a = Self.number(d, low, fallback), b = Self.number(d, high, a)
        return a + (b-a) * pow(random(), max(0.01, Self.number(d, "exponent", 1)))
    }
    private func controlPoint(_ id: Int, cursor: CGPoint?) -> SIMD2<Double> {
        let cp = (definition["controlpoint"] as? [[String: Any]])?.first { ($0["id"] as? Int ?? 0) == id } ?? [:]
        let offset = vector(cp["offset"])
        if (cp["flags"] as? Int ?? 0) & 1 != 0, let cursor { return SIMD2(cursor.x + offset.x, cursor.y + offset.y) }
        return SIMD2(offset.x, offset.y)
    }
    private func spawn(cursor: CGPoint?) {
        guard particles.count < maximum, !textures.isEmpty else { return }
        let angle = random() * .pi * 2
        let direction = vector(emitter["directions"], SIMD3(1,1,0))
        let radius = range(emitter, "distancemin", "distancemax", 0)
        let origin = vector(emitter["origin"])
        let center = controlPoint(0, cursor: cursor) + SIMD2(origin.x, origin.y)
        let unit = SIMD2(cos(angle), sin(angle))
        var velocity = unit * range(emitter, "speedmin", "speedmax", 0)
        var lifetime = 1.0, size = 16.0, alpha = 1.0
        var color = SIMD3<Double>(repeating: 1)
        for op in initializers {
            switch op["name"] as? String {
            case "lifetimerandom": lifetime = range(op, "min", "max", 1)
            case "sizerandom": size = range(op, "min", "max", 16)
            case "alpharandom": alpha = range(op, "min", "max", 1)
            case "velocityrandom", "colorrandom":
                let a = vector(op["min"]), b = vector(op["max"], a)
                let value = a + (b-a) * SIMD3(random(), random(), random())
                if op["name"] as? String == "velocityrandom" { velocity += SIMD2(value.x,value.y) }
                else { color = value / 255 }
            default: break
            }
        }
        if overrides["colorn"] != nil { color = vector(overrides["colorn"], color) }
        let texture = textures[min(textures.count-1, Int(random() * Double(textures.count)))]
        let sprite = SKSpriteNode(texture: texture)
        sprite.blendMode = additive ? .add : .alpha
        sprite.color = NSColor(red: min(1,max(0,color.x)), green: min(1,max(0,color.y)), blue: min(1,max(0,color.z)), alpha: 1)
        sprite.colorBlendFactor = 1
        addChild(sprite)
        let children = childFactory?() ?? []
        children.forEach { addChild($0) }
        let p = center + unit * radius * SIMD2(direction.x, direction.y)
        particles.append(Particle(sprite: sprite, position: p, velocity: velocity, lifetime: max(0.01,lifetime), size: max(0,size), alpha: alpha, phase: random() * .pi * 2, children: children))
    }
    func prewarm() {
        let seconds = min(20, max(0, Self.number(definition, "starttime", 0)))
        for _ in 0..<Int(seconds * 30) { advance(delta: 1/30, cursor: nil) }
    }
    func advance(delta: Double, cursor: CGPoint?) {
        let dt = min(0.1, max(0, delta)); elapsed += dt
        remainder += min(500, max(0, Self.number(emitter,"rate",10) * Self.number(overrides,"rate",1))) * dt
        let cursorEmitter = (definition["controlpoint"] as? [[String: Any]])?.contains { ($0["id"] as? Int ?? 0) == 0 && ($0["flags"] as? Int ?? 0) & 1 != 0 } == true
        let births = cursorEmitter && cursor == nil ? 0 : min(maximum, Int(remainder)); remainder -= floor(remainder)
        if births > 0 { for _ in 0..<births { spawn(cursor: cursor) } }
        for index in particles.indices.reversed() {
            var p = particles[index]; p.age += dt
            if p.age >= p.lifetime {
                p.sprite.removeFromParent(); p.children.forEach { $0.removeFromParent() }
                particles.remove(at:index); continue
            }
            let t = p.age / p.lifetime
            var alpha = p.alpha, size = p.size * Self.number(overrides,"size",1), offset = SIMD2<Double>.zero
            for op in operators {
                let n: (String, Double) -> Double = { Self.number(op,$0,$1) }
                switch op["name"] as? String {
                case "movement":
                    let gravity = vector(op["gravity"])
                    p.velocity += SIMD2(gravity.x, gravity.y) * dt
                    p.velocity *= exp(-max(0,n("drag",0))*dt)
                case "alphafade":
                    let fadeIn = max(0.0001,n("fadeintime",0.1)), fadeOut = min(0.9999,n("fadeouttime",0.9))
                    alpha *= min(1,t/fadeIn) * min(1,(1-t)/(1-fadeOut))
                case "sizechange":
                    let start = n("starttime",0), end = max(start+0.0001,n("endtime",1))
                    let progress = min(1,max(0,(t-start)/(end-start)))
                    size *= n("startvalue",1) + (n("endvalue",0)-n("startvalue",1))*progress
                case "oscillatealpha", "oscillatesize", "oscillateposition":
                    let frequency = (n("frequencymin",1)+n("frequencymax",n("frequencymin",1)))/2
                    let wave = (sin(p.age*frequency*2 * .pi+p.phase)+1)/2
                    let amount = n("scalemin",0)+(n("scalemax",1)-n("scalemin",0))*wave
                    if op["name"] as? String == "oscillatealpha" { alpha *= amount }
                    else if op["name"] as? String == "oscillatesize" { size *= amount }
                    else { offset += SIMD2(cos(p.phase+p.age),sin(p.phase+p.age))*amount }
                case "turbulence":
                    let speed = (n("speedmin",0)+n("speedmax",0))/2
                    p.velocity += SIMD2(cos(p.phase+elapsed),sin(p.phase+elapsed*0.73))*speed*dt
                case "controlpointattract":
                    let cp = controlPoint(Int(n("controlpoint",0)),cursor:cursor)
                    let difference = cp-p.position, distance = max(1,sqrt(difference.x*difference.x+difference.y*difference.y))
                    if distance < n("threshold",100) { p.velocity += difference/distance*n("scale",1)*dt }
                case "vortex":
                    let difference = p.position-controlPoint(0,cursor:cursor)
                    let distance = max(1,sqrt(difference.x*difference.x+difference.y*difference.y))
                    let ratio = min(1,max(0,(distance-n("distanceinner",0))/max(1,n("distanceouter",100)-n("distanceinner",0))))
                    let speed = n("speedinner",0)+(n("speedouter",0)-n("speedinner",0))*ratio
                    p.velocity += SIMD2(-difference.y,difference.x)/distance*speed*dt
                default: break
                }
            }
            p.position += p.velocity * dt
            p.sprite.position = CGPoint(x:p.position.x+offset.x,y:p.position.y+offset.y)
            let aspect = p.sprite.texture.map { $0.size().height / max(1,$0.size().width) } ?? 1
            p.sprite.size = CGSize(width:max(0,size),height:max(0,size*aspect))
            p.sprite.alpha = min(1,max(0,alpha))
            if overrides["colorn"] != nil {
                let c = vector(overrides["colorn"], SIMD3(repeating:1))
                p.sprite.color = NSColor(red:min(1,max(0,c.x)),green:min(1,max(0,c.y)),blue:min(1,max(0,c.z)),alpha:1)
            }
            if let renderer = (definition["renderer"] as? [[String:Any]])?.first, renderer["name"] as? String == "spritetrail" {
                let speed = sqrt(p.velocity.x*p.velocity.x+p.velocity.y*p.velocity.y)
                let stretch = min(Self.number(renderer,"maxlength",1), max(Self.number(renderer,"minlength",0),speed * Self.number(renderer,"length",0.05)))
                p.sprite.size.height += max(0,stretch)
                p.sprite.zRotation = atan2(p.velocity.y,p.velocity.x) - .pi/2
            }
            for child in p.children { child.position = p.sprite.position; child.advance(delta: dt, cursor: nil) }
            particles[index] = p
        }
    }
}
