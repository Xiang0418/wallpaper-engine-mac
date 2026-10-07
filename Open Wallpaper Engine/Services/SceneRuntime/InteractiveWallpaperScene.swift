import SpriteKit
import AppKit

/// Single update clock for scripts, input, particles and spectrum. Event monitors
/// belong to the view; application windows are excluded from desktop clicks.
final class InteractiveWallpaperScene: SKScene {
    var scriptRuntime: SceneScriptRuntime?
    var spectrumProvider: (() -> [Float])?
    private var lastTime: TimeInterval?
    private var trails: [(SKNode, SceneRopeTrail)] = []
    private var previousSpectrum: [Float]?
    private var audioOverlays: [(wrapper: SKNode, root: SKNode)] = []
    private var spectrumSprites: [SKSpriteNode] = []
    var effectsDidUpdate: ((Int, [[String: Any]]) -> Void)?
    private var stopped = false

    override var isPaused: Bool {
        didSet { lastTime = nil; if isPaused { scriptRuntime?.cancelPointer() } }
    }

    func install(objects: [[String: Any]], nodes: [Int: SKNode], contentNodes: [Int: SKNode], properties: [String: Any], storageKey: String,
                 asset: (String) -> Data?) {
        scriptRuntime = SceneScriptRuntime(objects: objects, nodes: nodes, contentNodes: contentNodes, properties: properties, size: size, storageKey: storageKey)
        for (index,object) in objects.enumerated() {
            guard let id = object["id"] as? Int, let node = nodes[id] else { continue }
            if let path = object["particle"] as? String, let data = asset(path),
               let definition = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let renderers = definition["renderer"] as? [[String: Any]],
               renderers.contains(where: { $0["name"] as? String == "rope" }) {
                let trail = SceneRopeTrail(definition: definition)
                trail.zPosition = CGFloat(index+1)
                addChild(trail); trails.append((node, trail))
            }
            if let sprite = contentNodes[id] as? SKSpriteNode,
               sprite.shader?.uniformNamed("u_audioSpectrum") != nil { spectrumSprites.append(sprite) }

        }
        // Keep the authored transform available to scripts. Viewport adaptation
        // moves a separate parent, including the cover and all sibling effects.
        var adapted = Set<ObjectIdentifier>()
        var roots: [SKNode] = []
        for sprite in spectrumSprites {
            var root: SKNode = sprite
            while let parent = root.parent, parent !== self { root = parent }
            guard root.parent === self, adapted.insert(ObjectIdentifier(root)).inserted else { continue }
            roots.append(root)
        }
        for root in roots {
            let wrapper = SKNode()
            root.removeFromParent()
            addChild(wrapper); wrapper.addChild(root)
            audioOverlays.append((wrapper, root))
        }
        scriptRuntime?.effectsDidUpdate = { [weak self] id, effects in
            self?.effectsDidUpdate?(id,effects)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        guard !stopped else { return }
        let dt = lastTime.map { min(0.1, max(0, currentTime-$0)) } ?? 0
        lastTime = currentTime
        var point: CGPoint?
        if let view, let window = view.window {
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let p = view.convert(windowPoint, from: nil)
            if view.bounds.contains(p) { point = convertPoint(fromView: p) }
        }
        scriptRuntime?.update(delta: dt, cursor: point ?? CGPoint(x: -1e6, y: -1e6))
        updateViewportLayout()
        for (node, trail) in trails {
            var hidden = node.isHidden
            var parent = node.parent
            while let current = parent { hidden = hidden || current.isHidden;parent = current.parent }
            trail.isHidden = hidden
            trail.update(delta: dt, cursor: point, enabled: !hidden)
        }
        let bins = spectrumProvider?() ?? Array(repeating:0,count:64)
        scriptRuntime?.setSpectrum(left: bins, right: bins)
        if !spectrumSprites.isEmpty, bins != previousSpectrum {
            let texture = SceneSpectrumTexture.texture(bins)
            for sprite in spectrumSprites { sprite.shader?.uniformNamed("u_audioSpectrum")?.textureValue = texture }
            previousSpectrum = bins
        }
    }

    func updateViewportLayout() {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let a = convertPoint(fromView: view.bounds.origin)
        let b = convertPoint(fromView: CGPoint(x:view.bounds.maxX, y:view.bounds.maxY))
        layoutAudioOverlays(in: CGRect(x:min(a.x,b.x), y:min(a.y,b.y),
                                      width:abs(b.x-a.x), height:abs(b.y-a.y)))
    }

    /// Remap only audio overlay groups into the visible part of an aspect-fill
    /// scene. Scripts retain their authored positions and cannot accumulate drift.
    func layoutAudioOverlays(in viewport: CGRect) {
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let cropped = viewport.width < size.width-0.5 || viewport.height < size.height-0.5
        for (wrapper, root) in audioOverlays {
            wrapper.position = .zero
            guard cropped else { continue }
            let bounds = root.calculateAccumulatedFrame()
            guard !bounds.isNull, !bounds.isInfinite else { continue }
            let safe = viewport.insetBy(dx:min(8,viewport.width/4), dy:min(8,viewport.height/4))
            let desired = CGPoint(x:viewport.minX+root.position.x/size.width*viewport.width,
                                  y:viewport.minY+root.position.y/size.height*viewport.height)
            func shift(_ desired: CGFloat, low: CGFloat, high: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
                // Oversized groups stay centered; do not distort their contents.
                if high-low > max-min { return (min+max-low-high)/2 }
                return Swift.min(max-high, Swift.max(min-low, desired))
            }
            wrapper.position = CGPoint(
                x:shift(desired.x-root.position.x, low:bounds.minX, high:bounds.maxX, min:safe.minX, max:safe.maxX),
                y:shift(desired.y-root.position.y, low:bounds.minY, high:bounds.maxY, min:safe.minY, max:safe.maxY))
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        scriptRuntime?.stop(); scriptRuntime = nil
        spectrumProvider = nil
        trails.removeAll(); spectrumSprites.removeAll(); audioOverlays.removeAll(); removeAllActions()
    }

    override func willMove(from view: SKView) { stop() }

}

final class InteractiveWallpaperView: SKView {
    private var monitor: Any?
    private var desktopPress = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        // Wallpaper windows remain click-through so Finder keeps normal desktop
        // behavior. Observe mouse gestures only when no application covers them.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.desktopEvent(event)
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func desktopEvent(_ event: NSEvent) {
        guard let scene = scene as? InteractiveWallpaperScene, !isPaused, !scene.isPaused,
              let window, window.isVisible else { desktopPress = false; return }
        let screenPoint = NSEvent.mouseLocation
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let point = scene.convertPoint(fromView: local)
        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(local), Self.desktopIsExposed(at: screenPoint) else { return }
            desktopPress = true
            scene.scriptRuntime?.mouseDown(at: point)
        case .leftMouseDragged:
            if desktopPress { scene.scriptRuntime?.moveCursor(to: point) }
        case .leftMouseUp:
            if desktopPress { scene.scriptRuntime?.mouseUp(at: point) }
            desktopPress = false
        default: break
        }
    }

    private static func desktopIsExposed(at point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let quartzPoint = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds), bounds.contains(quartzPoint) else { continue }
            return false
        }
        return true
    }

    override func layout() {
        super.layout()
        (scene as? InteractiveWallpaperScene)?.updateViewportLayout()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let scene = scene as? InteractiveWallpaperScene, !isPaused, !scene.isPaused else { return }
        scene.scriptRuntime?.mouseDown(at: event.location(in: scene))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let scene = scene as? InteractiveWallpaperScene, !isPaused, !scene.isPaused else { return }
        scene.scriptRuntime?.moveCursor(to: event.location(in: scene))
    }
    override func mouseUp(with event: NSEvent) {
        guard let scene = scene as? InteractiveWallpaperScene, !isPaused, !scene.isPaused else { return }
        scene.scriptRuntime?.mouseUp(at: event.location(in: scene))
    }
}
