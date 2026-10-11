//
//  SceneModels.swift
//  Open Wallpaper Engine
//
//  Data models for Wallpaper Engine scene.json structure.
//  Decoded from scene.pkg → scene.json and referenced JSON files.
//

import Foundation

// MARK: - Top-level Scene

struct WEScene: Codable {
    var camera: WECamera
    var general: WESceneGeneral
    var objects: [WESceneObject]
    var version: Int?
}

struct WECamera: Codable {
    var center: String?
    var eye: String?
    var up: String?
}

struct WESceneGeneral: Codable {
    var clearcolor: String?
    var orthogonalprojection: WEOrthogonalProjection?
    var ambientcolor: String?
    var skylightcolor: String?
    var zoom: Double?

    // These fields can be Bool, Int, or an object {"user":..,"value":..} in different wallpapers.
    // We only need the String fields above for rendering, so skip strict decoding of the rest.

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Use try? because these fields can be plain strings OR {"user":..,"value":..} objects
        clearcolor = (try? container.decode(String.self, forKey: .clearcolor))
            ?? (try? container.decode(WEStoredValue<String>.self, forKey: .clearcolor))?.value
        zoom = (try? container.decode(Double.self, forKey: .zoom))
            ?? (try? container.decode(WEStoredValue<Double>.self, forKey: .zoom))?.value
        orthogonalprojection = try? container.decodeIfPresent(WEOrthogonalProjection.self, forKey: .orthogonalprojection)
        ambientcolor = try? container.decodeIfPresent(String.self, forKey: .ambientcolor)
        skylightcolor = try? container.decodeIfPresent(String.self, forKey: .skylightcolor)
    }

    enum CodingKeys: String, CodingKey {
        case clearcolor, orthogonalprojection, ambientcolor, skylightcolor, zoom
    }
}

struct WEOrthogonalProjection: Codable {
    var width: Int
    var height: Int
}

// MARK: - Scene Objects

/// Many WE scene fields can be either a plain value or a {"script":"..","value":..} object.
/// This wrapper decodes the plain value and uses their stored value without executing scripts.
private func decodeFlexible<T: Decodable>(_ type: T.Type, container: KeyedDecodingContainer<WESceneObject.CodingKeys>, key: WESceneObject.CodingKeys) -> T? {
    if let value = try? container.decode(T.self, forKey: key) { return value }
    return (try? container.decode(WEStoredValue<T>.self, forKey: key))?.value
}

private struct WEStoredValue<T: Decodable>: Decodable {
    let value: T
}

struct WESceneObject: Codable {
    var sound: [String]?
    var volume: Double?
    var playbackmode: String?
    var startsilent: Bool?
    var parent: Int?
    var disablepropagation: Bool?
    var text: String?
    var font: String?
    var pointsize: Double?
    var horizontalalign: String?
    var verticalalign: String?
    var padding: String?
    var effects: [WEEffect]?
    var instance: WEMaterialPass?
    // Common
    var id: Int?
    var name: String?
    var origin: String?
    var scale: String?
    var angles: String?
    var visible: Bool?

    // Image objects
    var image: String?       // path to model JSON
    var alpha: Double?
    var brightness: Double?
    var color: String?
    var colorBlendMode: Int?
    var size: String?
    var alignment: String?
    var solid: Bool?
    var copybackground: Bool?
    var parallaxDepth: String?
    var perspective: Bool?

    // Particle objects
    var particle: String?    // path to particle JSON
    var instanceoverride: WEInstanceOverride?

    enum CodingKeys: String, CodingKey {
        case parent, disablepropagation, text, font, pointsize, horizontalalign, verticalalign, padding, effects, instance
        case id, name, origin, scale, angles, visible
        case image, alpha, brightness, color, colorBlendMode, size, alignment
        case solid, copybackground, parallaxDepth, perspective
        case particle, instanceoverride, sound, volume, playbackmode, startsilent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parent = try? c.decode(Int.self, forKey: .parent)
        disablepropagation = try? c.decode(Bool.self, forKey: .disablepropagation)
        text = decodeFlexible(String.self, container: c, key: .text)
        font = decodeFlexible(String.self, container: c, key: .font)
        pointsize = decodeFlexible(Double.self, container: c, key: .pointsize)
        horizontalalign = decodeFlexible(String.self, container: c, key: .horizontalalign)
        verticalalign = decodeFlexible(String.self, container: c, key: .verticalalign)
        padding = decodeFlexible(String.self, container: c, key: .padding)
        effects = try? c.decode([WEEffect].self, forKey: .effects)
        instance = try? c.decode(WEMaterialPass.self, forKey: .instance)
        sound = try? c.decodeIfPresent([String].self, forKey: .sound)
        volume = decodeFlexible(Double.self, container: c, key: .volume)
        playbackmode = try? c.decodeIfPresent(String.self, forKey: .playbackmode)
        startsilent = decodeFlexible(Bool.self, container: c, key: .startsilent)
        // Fields that are always simple types
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        particle = try? c.decodeIfPresent(String.self, forKey: .particle)
        instanceoverride = try? c.decodeIfPresent(WEInstanceOverride.self, forKey: .instanceoverride)

        // Fields that may be simple values or {"script":..,"value":..} objects
        origin = decodeFlexible(String.self, container: c, key: .origin)
        scale = decodeFlexible(String.self, container: c, key: .scale)
        angles = decodeFlexible(String.self, container: c, key: .angles)
        visible = decodeFlexible(Bool.self, container: c, key: .visible)
        alpha = decodeFlexible(Double.self, container: c, key: .alpha)
        brightness = decodeFlexible(Double.self, container: c, key: .brightness)
        color = decodeFlexible(String.self, container: c, key: .color)
        colorBlendMode = try? c.decodeIfPresent(Int.self, forKey: .colorBlendMode)
        size = decodeFlexible(String.self, container: c, key: .size)
        alignment = try? c.decodeIfPresent(String.self, forKey: .alignment)
        solid = try? c.decodeIfPresent(Bool.self, forKey: .solid)
        copybackground = try? c.decodeIfPresent(Bool.self, forKey: .copybackground)
        parallaxDepth = try? c.decodeIfPresent(String.self, forKey: .parallaxDepth)
        perspective = try? c.decodeIfPresent(Bool.self, forKey: .perspective)
    }
}

struct WEInstanceOverride: Codable {
    var id: Int?
    var colorn: String?
    var rate: WEScriptValue?
    var size: Double?
}

struct WEScriptValue: Codable {
    var script: String?
    var value: Double?

    init(from decoder: Decoder) throws {
        // Can be just a number or an object with script+value
        if let container = try? decoder.singleValueContainer(),
           let num = try? container.decode(Double.self) {
            self.value = num
            self.script = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.script = try container.decodeIfPresent(String.self, forKey: .script)
            self.value = try container.decodeIfPresent(Double.self, forKey: .value)
        }
    }

    enum CodingKeys: String, CodingKey {
        case script, value
    }
}

// MARK: - Model / Material

struct WEModel: Codable {
    var autosize: Bool?
    var material: String?    // path to material JSON
}

struct WEMaterial: Codable {
    var passes: [WEMaterialPass]?
}

struct WEMaterialPass: Codable {
    var blending: String?    // "translucent", "additive"
    var shader: String?
    var textures: [String?]?
    var usertextures: [WEJSONValue]?
    var usesMediaThumbnail: Bool {
        guard let first = usertextures?.first, case .object(let binding) = first else { return false }
        return binding["name"]?.string == "$mediaThumbnail" && binding["type"]?.string == "system"
    }
    var constantshadervalues: [String: WEJSONValue]?
    var combos: [String: Int]?
    var cullmode: String?
    var depthtest: String?
    var depthwrite: String?
}

// MARK: - Particle System

struct WEParticleSystem: Codable {
    var emitter: [WEParticleEmitter]?
    var initializer: [WEParticleInitializer]?
    var `operator`: [WEParticleOperator]?
    var renderer: [WEParticleRenderer]?
    var material: String?
    var maxcount: Int?
    var flags: Int?
    var starttime: Double?
    var animationmode: String?
    var sequencemultiplier: Double?
}

struct WEParticleEmitter: Codable {
    var id: Int?
    var name: String?
    var rate: Double?
    var origin: String?
    var directions: String?
    var distancemax: Double?
    var distancemin: Double?
    var speedmax: Double?
    var speedmin: Double?
}

struct WEParticleInitializer: Codable {
    var id: Int?
    var name: String?
    var min: WEFlexValue?
    var max: WEFlexValue?
}

/// A value that can be either a number or a string (e.g. "0 -3000 0")
enum WEFlexValue: Codable {
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            self = .number(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }

    var doubleValue: Double {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s) ?? 0
        }
    }

    var vectorValue: (Double, Double, Double) {
        switch self {
        case .number(let n): return (n, n, n)
        case .string(let s): return s.parseVector3()
        }
    }
}

struct WEParticleOperator: Codable {
    var id: Int?
    var name: String?
    var gravity: String?
    var drag: Double?
    var fadeintime: Double?
    var fadeouttime: Double?
}

struct WEParticleRenderer: Codable {
    var id: Int?
    var name: String?       // "sprite", "spritetrail"
    var length: Double?
    var maxlength: Double?
}

// MARK: - String Parsing Helpers

extension String {
    /// Parse "x y z" space-separated vector string
    func parseVector3() -> (Double, Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0
        )
    }

    /// Parse "x y" space-separated 2D vector
    func parseVector2() -> (Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0
        )
    }

    /// Parse "r g b" color string (0-1 range) to NSColor
    func parseColor() -> (r: Double, g: Double, b: Double) {
        let v = self.parseVector3()
        return (r: v.0, g: v.1, b: v.2)
    }
}

/// Lossless JSON values keep shader parameters and wrapped stored values available.
indirect enum WEJSONValue: Codable {
    case number(Double), string(String), bool(Bool), object([String: WEJSONValue]), array([WEJSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: WEJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([WEJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var stored: WEJSONValue { if case .object(let v) = self { return v["value"]?.stored ?? .null }; return self }
    var number: Double? { if case .number(let v) = stored { return v }; return nil }
    var string: String? { if case .string(let v) = stored { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = stored { return v }; return nil }
}
struct WEEffect: Codable {
    var file: String
    var visible: WEJSONValue?
    var passes: [WEMaterialPass]?
}

extension WEScene {
    /// Apply direct project-default bindings before typed decoding. Script expressions
    /// retain their exported value until the SceneScript runtime is implemented.
    static func decode(data: Data, projectData: Data?) throws -> WEScene {
        let root = try JSONSerialization.jsonObject(with: data)
        var properties: [String: Any] = [:]
        if let projectData = projectData,
           let project = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any],
           let general = project["general"] as? [String: Any] {
            properties = general["properties"] as? [String: Any] ?? [:]
        }
        func resolve(_ input: Any) -> Any {
            if let array = input as? [Any] { return array.map(resolve) }
            guard var object = input as? [String: Any] else { return input }
            if let key = object["user"] as? String, let property = properties[key] as? [String: Any],
               let value = property["value"], let stored = object["value"] {
                // A slider bound to a vector needs engine conversion; don't replace it
                // with a scalar and silently destroy the exported transform.
                if (value is String && stored is String) || (value is NSNumber && stored is NSNumber) {
                    object["value"] = value
                }
            }
            return object.mapValues(resolve)
        }
        return try JSONDecoder().decode(WEScene.self, from: JSONSerialization.data(withJSONObject: resolve(root)))
    }
}
