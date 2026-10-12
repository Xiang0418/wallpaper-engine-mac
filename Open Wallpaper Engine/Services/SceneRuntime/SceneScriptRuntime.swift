import AppKit
import JavaScriptCore
import SpriteKit

/// Main-thread scene runtime. The renderer owns nodes; this object owns script state.
/// Raw JSON preserves nested effect scripts without changing phase-two Codable models.
final class SceneScriptRuntime {
    private let context = JSContext()!
    private var nodes: [Int: SKNode]
    private var contentNodes: [Int: SKNode]
    private var interactiveIDs = Set<Int>()
    private var originalCustomTextures: [String: SKTexture] = [:]
    private var originalTextures: [Int: SKTexture] = [:]
    private let objects: [[String: Any]]
    private var properties: [String: Any]
    private var stopped = false
    private var allowShortcut = false
    private var hovered: Int?
    private var pressed: Int?
    private var pressPoint = CGPoint.zero
    private var cursor = CGPoint(x: -1e6, y: -1e6)
    private var moved = false
    var diagnostics: [String] = []
    /// Phase-two effects can consume the original nested effect values after each update.
    var effectsDidUpdate: ((Int, [[String: Any]]) -> Void)?
    var openShortcut: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(objects: [[String: Any]], nodes: [Int: SKNode], contentNodes: [Int: SKNode]? = nil, properties: [String: Any], size: CGSize, storageKey: String) {
        self.objects = objects
        self.nodes = nodes
        self.contentNodes = contentNodes ?? nodes
        self.properties = properties
        originalTextures = self.contentNodes.compactMapValues { ($0 as? SKSpriteNode)?.texture }
        let log: @convention(block) (String) -> Void = { [weak self] message in
            guard let self else { return }
            if self.diagnostics.count < 100 { self.diagnostics.append(message) }
            NSLog("[SceneScript] %@", message)
        }
        let read: @convention(block) (String) -> String = { key in
            UserDefaults.standard.string(forKey: "SceneScript.\(storageKey).\(key)") ?? "null"
        }
        let write: @convention(block) (String, String) -> Void = { key, value in
            guard key.count < 256, value.utf8.count <= 65536 else { return }
            UserDefaults.standard.set(value, forKey: "SceneScript.\(storageKey).\(key)")
        }
        let shortcut: @convention(block) (String) -> Void = { [weak self] key in
            guard let self, self.allowShortcut,
                  let target = self.properties[key] as? String,
                  let url = Self.shortcutURL(target) else { return }
            self.allowShortcut = false // one launch per physical click
            self.openShortcut(url)
        }
        context.setObject(log, forKeyedSubscript: "nativeLog" as NSString)
        context.setObject(read, forKeyedSubscript: "nativeRead" as NSString)
        context.setObject(write, forKeyedSubscript: "nativeWrite" as NSString)
        context.setObject(shortcut, forKeyedSubscript: "nativeShortcut" as NSString)
        context.exceptionHandler = { _, error in log(error?.toString() ?? "JavaScript error") }
        context.evaluateScript(SceneScriptBootstrap.source)
        context.objectForKeyedSubscript("loadScene")?.call(withArguments: [objects, properties, size.width, size.height])
        if let ids = context.evaluateScript("scripts.filter(s=>Object.keys(s.events).some(k=>k.startsWith('cursor')&&s.events[k])).map(s=>s.layer.id)")?.toArray() as? [Int] {
            interactiveIDs = Set(ids)
        }
        synchronizeNodes()
        refreshShortcutTextures()
        refreshCustomTextures()
    }

    /// No shell execution, Windows commands or arbitrary URL handlers. User-selected
    /// .app bundles, ordinary documents and web links use Launch Services.
    static func shortcutURL(_ target: String) -> URL? {
        if target.hasPrefix("/") {
            let url = URL(fileURLWithPath: target).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  !["exe", "bat", "cmd", "sh", "command", "scpt"].contains(url.pathExtension.lowercased()) else { return nil }
            return url
        }
        guard let url = URL(string: target), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    func applyUserProperties(_ changes: [String: Any]) {
        guard !stopped else { return }
        properties.merge(changes) { _, new in new }
        context.objectForKeyedSubscript("applyProperties")?.call(withArguments: [changes])
        synchronizeNodes()
        refreshShortcutTextures(changed:Set(changes.keys))
        refreshCustomTextures(changed: Set(changes.keys))
    }

    func update(delta: TimeInterval, cursor: CGPoint) {
        guard !stopped else { return }
        context.objectForKeyedSubscript("tick")?.call(withArguments: [min(max(delta, 0), 0.1), cursor.x, cursor.y])
        synchronizeNodes()
        moveCursor(to: cursor)
    }

    func setSpectrum(left: [Float], right: [Float]) {
        guard !stopped else { return }
        context.objectForKeyedSubscript("setSpectrum")?.call(withArguments: [left, right])
    }

    func cancelPointer() {
        if let pressed { event("cursorUp",pressed,cursor) }
        pressed=nil; moved=true; allowShortcut=false
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        context.objectForKeyedSubscript("shutdown")?.call(withArguments: [])
        nodes.removeAll(); contentNodes.removeAll(); originalTextures.removeAll(); originalCustomTextures.removeAll()
        hovered = nil; pressed = nil
    }

    private func event(_ name: String, _ id: Int, _ point: CGPoint) {
        context.objectForKeyedSubscript("cursorEvent")?.call(withArguments: [name, id, point.x, point.y])
    }

    func moveCursor(to point: CGPoint) {
        guard !stopped else { return }
        let hit = hitTest(point)
        if hit != hovered {
            if let old = hovered { event("cursorLeave", old, point) }
            if let hit { event("cursorEnter", hit, point) }
            hovered = hit
        }
        if point != cursor {
            if let pressed { event("cursorMove", pressed, point) }
            else if let hit { event("cursorMove", hit, point) }
            if hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 4 { moved = true }
        }
        cursor = point
    }

    func mouseDown(at point: CGPoint) {
        guard !stopped else { return }
        moveCursor(to: point)
        pressed = hitTest(point); pressPoint = point; moved = false
        if let pressed { event("cursorDown", pressed, point) }
    }

    func mouseUp(at point: CGPoint) {
        guard !stopped else { return }
        moveCursor(to: point)
        if let pressed {
            event("cursorUp", pressed, point)
            if !moved && hitTest(point) == pressed {
                allowShortcut = true
                event("cursorClick", pressed, point)
                allowShortcut = false
            }
        }
        pressed = nil
        synchronizeNodes()
    }

    private func hitTest(_ point: CGPoint) -> Int? {
        // Hit geometry must include invisible interactive drag handles (WE uses
        // cursorEnter to reveal them), but never a hidden parent or disabled dock.
        for object in objects.reversed() {
            guard let id = object["id"] as? Int, let node = nodes[id], let scene = node.scene else { continue }
            var ancestor = node.parent
            var hidden = false
            while let parent = ancestor { hidden = hidden || parent.isHidden; ancestor = parent.parent }
            if hidden { continue }
            guard interactiveIDs.contains(id) else { continue }
            if node.isHidden && !(object["name"] as? String == "Drag and Drop") { continue }
            let content = contentNodes[id] ?? node
            let local = content.convert(point, from: scene)
            if let sprite = content as? SKSpriteNode {
                let rect = CGRect(x: -sprite.anchorPoint.x * sprite.size.width, y: -sprite.anchorPoint.y * sprite.size.height, width: sprite.size.width, height: sprite.size.height)
                if rect.contains(local) { return id }
            }
        }
        return nil
    }

    private func refreshShortcutTextures(changed:Set<String>? = nil) {
        for object in objects {
            guard let id=object["id"] as? Int,let sprite=contentNodes[id] as? SKSpriteNode,
                  let instance=object["instance"] as? [String:Any],
                  let bindings=instance["usertextures"] as? [[String:Any]],
                  let binding=bindings.first(where:{$0["type"] as? String == "usershortcut"}),
                  let key=binding["name"] as? String,changed == nil || changed!.contains(key) else { continue }
            if let target=properties[key] as? String,let url=Self.shortcutURL(target),url.isFileURL {
                sprite.texture=SKTexture(image:NSWorkspace.shared.icon(forFile:url.path))
            } else { sprite.texture=originalTextures[id] }
        }
    }

    private func refreshCustomTextures(changed: Set<String>? = nil) {
        for object in objects {
            guard let id = object["id"] as? Int, let sprite = contentNodes[id] as? SKSpriteNode,
                  let effects = object["effects"] as? [[String: Any]] else { continue }
            for (index, effect) in effects.enumerated() {
                guard let passes = effect["passes"] as? [[String: Any]],
                      let bindings = passes.first?["usertextures"] as? [Any], bindings.count > 1,
                      let name = bindings[1] as? String, changed == nil || changed!.contains(name),
                      let uniform = sprite.shader?.uniformNamed("custom\(index)") else { continue }
                let cacheKey = "\(id).\(index)"
                if originalCustomTextures[cacheKey] == nil { originalCustomTextures[cacheKey] = uniform.textureValue }
                if let path = properties[name] as? String, path.hasPrefix("/"),
                   let image = NSImage(contentsOfFile: path) {
                    uniform.textureValue = SKTexture(image: image)
                } else { uniform.textureValue = originalCustomTextures[cacheKey] }
            }
        }
    }

    func replaceContentNode(id: Int, with node: SKNode) {
        contentNodes[id] = node
    }

    private func synchronizeNodes() {
        guard let states = context.evaluateScript("layers") else { return }
        for (index, object) in objects.enumerated() {
            guard let id = object["id"] as? Int, let node = nodes[id], let state = states.atIndex(index) else { continue }
            func number(_ value: JSValue?, _ fallback: Double) -> Double {
                guard let value, !value.isUndefined, !value.isNull else { return fallback }
                let n = value.toDouble(); return n.isFinite ? n : fallback
            }
            let origin = state.forProperty("origin"), scale = state.forProperty("scale")
            node.position = CGPoint(x: number(origin?.forProperty("x"), Double(node.position.x)), y: number(origin?.forProperty("y"), Double(node.position.y)))
            node.xScale = number(scale?.forProperty("x"), 1)
            node.yScale = number(scale?.forProperty("y"), 1)
            node.zRotation = number(state.forProperty("angles")?.forProperty("z"), 0) * .pi / 180
            if let overrides = state.forProperty("instanceoverride")?.toDictionary() as? [String:Any] {
                node.children.compactMap { $0 as? SceneSpriteParticles }.forEach { $0.applyOverrides(overrides) }
            }
            let content = contentNodes[id] ?? node
            content.alpha = min(1, max(0, number(state.forProperty("alpha"), 1)))
            node.isHidden = !(state.forProperty("visible")?.toBool() ?? true)
            if let label = content as? SKLabelNode, let text = state.forProperty("text")?.toString() {
                if let textNode = label as? SceneTextNode {
                    textNode.updateText(text)
                } else if let attributed = label.attributedText, attributed.length > 0 {
                    if attributed.string != text { label.attributedText = NSAttributedString(string:text,attributes:attributed.attributes(at:0,effectiveRange:nil)) }
                } else if label.text != text { label.text = text }
            }
            if let sprite = content as? SKSpriteNode {
                if let color = state.forProperty("color"), !color.isUndefined {
                    let rgb = SIMD3<Float>(Float(number(color.forProperty("x"),1)),Float(number(color.forProperty("y"),1)),Float(number(color.forProperty("z"),1)))
                    sprite.shader?.uniformNamed("u_layerTint")?.vectorFloat3Value = rgb
                }
                switch state.forProperty("alignment")?.toString() {
                case "bottom": sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
                case "top": sprite.anchorPoint = CGPoint(x: 0.5, y: 1)
                case "left": sprite.anchorPoint = CGPoint(x: 0, y: 0.5)
                case "right": sprite.anchorPoint = CGPoint(x: 1, y: 0.5)
                default: break
                }
            }
            if let effects = state.forProperty("effects")?.toArray() as? [[String: Any]] { effectsDidUpdate?(id, effects) }
        }
    }
}

/// Text is laid out in the exported layer rectangle. Its alignment is independent
/// of the parent transform/anchor, and changing digits must not move the baseline.
final class SceneTextNode: SKLabelNode {
    private(set) var layoutBounds: CGRect = .zero
    private let layoutSize: CGSize
    private let padding: CGSize
    private let horizontal: String
    private let vertical: String
    private let textFont: NSFont
    private let textColor: NSColor

    init(text: String, font: NSFont, color: NSColor, size: CGSize, padding: CGSize,
         horizontal: String, vertical: String) {
        self.layoutSize = size; self.padding = padding
        self.horizontal = horizontal; self.vertical = vertical
        self.textFont = font; self.textColor = color
        super.init()
        horizontalAlignmentMode = horizontal == "right" ? .right : horizontal == "left" ? .left : .center
        verticalAlignmentMode = .baseline
        updateText(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateText(_ text: String) {
        guard attributedText?.string != text else { return }
        let attributed = NSAttributedString(string: text, attributes: [.font: textFont, .foregroundColor: textColor])
        attributedText = attributed
        let width = attributed.size().width
        let lineHeight = textFont.ascender - textFont.descender
        // Padding extends the texture allocation, not the text advance or anchor.
        // Keep the baseline independent of the current digits.
        let px = max(0, padding.width), py = max(0, padding.height)
        let w = max(layoutSize.width, width + 2 * px)
        let h = max(layoutSize.height, lineHeight + 2 * py)
        let boxX = horizontal == "left" ? 0 : horizontal == "right" ? -w : -w/2
        // SpriteKit aligns its rendered glyph rectangle, which can differ from
        // the typographic advance (especially the bundled rounded digits).
        let x = 0.0
        let y = vertical == "top" ? -textFont.ascender
            : vertical == "bottom" ? -textFont.descender
            : -textFont.ascender/2
        layoutBounds = CGRect(x: boxX, y: vertical == "top" ? -h : vertical == "bottom" ? 0 : -h/2, width: w, height: h)
        position = CGPoint(x: x, y: y)
    }
}
