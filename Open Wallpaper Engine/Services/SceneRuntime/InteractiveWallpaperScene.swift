import SpriteKit
import AppKit

/// Single update clock for scripts, input, particles and spectrum. Event monitors
/// belong to the view; application windows are excluded from desktop clicks.
final class InteractiveWallpaperScene: SKScene {
    var scriptRuntime: SceneScriptRuntime?
    var spectrumProvider: (() -> [Float])?
    private var lastTime: TimeInterval?
    private var cursorHistory = SceneCursorHistory()
    private var puppets: [ScenePuppetNode] = []
    private var spriteParticles: [SceneSpriteParticles] = []
    func bindParticles(_ system: SceneSpriteParticles) { spriteParticles.append(system) }
    private var trails: [(SKNode, SceneRopeTrail)] = []
    private var previousSpectrum: [Float]?
    private var audioOverlays: [(wrapper: SKNode, root: SKNode)] = []
    private var spectrumSprites: [SKSpriteNode] = []
    var effectsDidUpdate: ((Int, [[String: Any]]) -> Void)?
    private var stopped = false
    private var videoPlaybackRate: Float = 1
    func setVideoPlaybackRate(_ rate: Float) {
        videoPlaybackRate = rate
        for (_, video) in videoSprites { video.player.rate = isPaused || stopped ? 0 : rate }
    }
    private var textureAnimations: [(SKSpriteNode, SceneTextureAnimation)] = []
    private var videoSprites: [(SKSpriteNode, SceneVideoTexture)] = []
    private var scrollSprites: [SKSpriteNode] = []
    private var effectTime: Double = 0
    private let mediaConsumerID = UUID()
    private var mediaInstalled = false
    private var offlineExport = false
    private var artworkRevision = -1
    private var mediaBindings: [SceneMediaArtworkBinding] = []

    func bindTextureAnimation(node: SKSpriteNode, textures: [SKTexture], durations: [Double]) {
        guard textures.count == durations.count, !textures.isEmpty else { return }
        let animation = SceneTextureAnimation(textures: textures, durations: durations)
        node.texture = animation.texture
        textureAnimations.append((node, animation))
    }


    override var isPaused: Bool {
        didSet {
            guard oldValue != isPaused else { return }
            lastTime = nil; cursorHistory.reset()
            setVideoPlaybackRate(videoPlaybackRate)
            if mediaInstalled { ExternalMediaService.shared.setConsumer(mediaConsumerID, active: !isPaused && !stopped) }
            if isPaused {
                scriptRuntime?.cancelPointer()
                for (_, trail) in trails { trail.disconnectCursor() }
            }
        }
    }

    func install(objects: [[String: Any]], nodes: [Int: SKNode], contentNodes: [Int: SKNode], properties: [String: Any], storageKey: String, offline: Bool = false,
                 asset: (String) -> Data?) {
        offlineExport = offline
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
            if let puppet = contentNodes[id] as? ScenePuppetNode { puppets.append(puppet) }
            if let sprite = contentNodes[id] as? SKSpriteNode {
                if let video = sprite.userData?["videoTexture"] as? SceneVideoTexture { videoSprites.append((sprite, video)) }
                if sprite.userData?["mediaThumbnail"] as? Bool == true { mediaBindings.append(SceneMediaArtworkBinding(sprite: sprite)) }
                if sprite.shader?.uniformNamed("u_audioSpectrum") != nil { spectrumSprites.append(sprite) }
                if sprite.shader?.uniformNamed("u_scrollTime") != nil { scrollSprites.append(sprite) }
            }

        }
        mediaInstalled = !offline
        if mediaInstalled { ExternalMediaService.shared.setConsumer(mediaConsumerID, active: !isPaused) }
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

    func recordCursor(_ point: CGPoint?, at time: TimeInterval) {
        guard !stopped, !isPaused else { return }
        cursorHistory.record(point, at: time)
    }

    override func update(_ currentTime: TimeInterval) {
        guard !stopped, !isPaused else { return }
        let dt = lastTime.map { min(0.1, max(0, currentTime-$0)) } ?? 0
        lastTime = currentTime
        let snapshot: () -> (SKTexture?, Int, NowPlayingSnapshot, Bool) = {
            let media = ExternalMediaService.shared
            return (media.artworkTexture, media.artworkRevision, media.nowPlaying, media.artworkEnabled)
        }
        let (artwork, revision, playing, enabled) = offlineExport && !Thread.isMainThread
            ? DispatchQueue.main.sync(execute: snapshot) : snapshot()
        scriptRuntime?.applyMedia(title: playing.title, artist: playing.artist, playing: playing.playing, enabled: enabled)
        for (node, animation) in textureAnimations where !(node.userData?["mediaThumbnail"] as? Bool == true && artwork != nil) {
            animation.advance(dt); node.texture = animation.texture
        }
        for (sprite, video) in videoSprites { video.update(sprite) }
        effectTime += dt
        for sprite in scrollSprites { sprite.shader?.uniformNamed("u_scrollTime")?.floatValue = Float(effectTime) }
        var point: CGPoint?
        if let view, let window = view.window {
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let p = view.convert(windowPoint, from: nil)
            if view.bounds.contains(p) { point = convertPoint(fromView: p) }
        }
        let bins = spectrumProvider?() ?? Array(repeating:0,count:64)
        scriptRuntime?.setSpectrum(left: bins, right: bins)
        scriptRuntime?.update(delta: dt, cursor: point ?? CGPoint(x: -1e6, y: -1e6))
        for puppet in puppets { puppet.advance(dt) }
        if revision != artworkRevision {
            mediaBindings.forEach { $0.apply(artwork) }
            artworkRevision = revision
        }
        updateViewportLayout()
        for system in spriteParticles {
            var ancestor: SKNode? = system
            var hidden = false
            while let node = ancestor { hidden = hidden || node.isHidden; ancestor = node.parent }
            if !hidden { system.advance(delta: dt, cursor: point.map { system.convert($0, from: self) }) }
        }
        let samples = cursorHistory.consume(until: ProcessInfo.processInfo.systemUptime, frameDuration: dt, current: point)
        for (node, trail) in trails {
            var hidden = node.isHidden
            var parent = node.parent
            while let current = parent { hidden = hidden || current.isHidden;parent = current.parent }
            trail.isHidden = hidden
            for sample in samples {
                trail.update(delta: sample.delta, cursor: sample.point, enabled: !hidden, render: false)
            }
            trail.update(delta: 0, cursor: point, enabled: !hidden)
        }
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

    func activateLiveMedia() {
        dispatchPrecondition(condition: .onQueue(.main))
        offlineExport = false
        mediaInstalled = true
        ExternalMediaService.shared.setConsumer(mediaConsumerID, active: !isPaused && !stopped)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if mediaInstalled { ExternalMediaService.shared.setConsumer(mediaConsumerID, active: false) }
        mediaInstalled = false
        mediaBindings.forEach { $0.apply(nil) }; mediaBindings.removeAll()
        cursorHistory.reset()
        scriptRuntime?.stop(); scriptRuntime = nil
        spectrumProvider = nil
        puppets.removeAll()
        textureAnimations.removeAll(); scrollSprites.removeAll()
        videoSprites.forEach { $0.1.stop() }; videoSprites.removeAll()
        spriteParticles.removeAll(); trails.removeAll(); spectrumSprites.removeAll(); audioOverlays.removeAll(); removeAllActions()
    }

    override func willMove(from view: SKView) { stop() }

}

final class InteractiveWallpaperView: SKView {
    private var monitor: Any?
    private var localMonitor: Any?
    private var desktopPress = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        guard window != nil else { return }
        // Wallpaper windows remain click-through so Finder keeps normal desktop
        // behavior. Observe mouse gestures only when no application covers them.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            self?.recordCursorMotion()
            self?.desktopEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            self?.recordCursorMotion()
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func recordCursorMotion() {
        guard !isPaused, let scene = scene as? InteractiveWallpaperScene,
              let window, window.isVisible else { return }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        scene.recordCursor(bounds.contains(local) ? scene.convertPoint(fromView: local) : nil,
                           at: ProcessInfo.processInfo.systemUptime)
    }

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


/// Preserve motion between render frames. The queue is bounded even when drawing
/// stalls; old samples are discarded instead of replayed after pause or wake.
struct SceneCursorHistory {
    struct Sample { let point: CGPoint?; let time: TimeInterval }
    struct Step { let point: CGPoint?; let delta: TimeInterval }
    private var pending: [Sample] = []
    private var lastFrame: TimeInterval?
    var count: Int { pending.count }

    mutating func record(_ point: CGPoint?, at time: TimeInterval) {
        guard time.isFinite, point.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else { return }
        guard pending.last.map({ time >= $0.time }) ?? true else { return }
        pending.append(Sample(point: point, time: time))
        if pending.count > 256 { pending.removeFirst(pending.count - 256) }
    }

    mutating func consume(until now: TimeInterval, frameDuration: TimeInterval, current: CGPoint?) -> [Step] {
        let start = max(lastFrame ?? (now - frameDuration), now - min(0.1, max(0, frameDuration)))
        var time = start
        var result: [Step] = []
        for sample in pending where sample.time >= start && sample.time <= now {
            result.append(Step(point: sample.point, delta: sample.time - time))
            time = sample.time
        }
        result.append(Step(point: current, delta: max(0, now - time)))
        pending.removeAll(keepingCapacity: true)
        lastFrame = now
        return result
    }

    mutating func reset() { pending.removeAll(keepingCapacity: true); lastFrame = nil }
}


/// Unequal frame durations share the scene's pause-aware clock.
final class SceneTextureAnimation {
    private let textures: [SKTexture]
    private let durations: [Double]
    private let cycle: Double
    private var elapsed = 0.0
    private(set) var frameIndex = 0
    var texture: SKTexture { textures[frameIndex] }
    init(textures: [SKTexture], durations: [Double]) {
        precondition(!textures.isEmpty && textures.count == durations.count)
        self.textures = textures
        self.durations = durations.map { $0.isFinite && $0 > 0 ? $0 : 1.0/30 }
        cycle = self.durations.reduce(0, +)
    }
    func advance(_ delta: Double) {
        guard delta.isFinite, delta > 0 else { return }
        elapsed = (elapsed + delta).truncatingRemainder(dividingBy: cycle)
        var remaining = elapsed
        frameIndex = textures.count - 1
        for index in durations.indices {
            if remaining < durations[index] { frameIndex = index; break }
            remaining -= durations[index]
        }
    }
}
