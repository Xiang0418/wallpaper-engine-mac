//
//  SceneWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Loads and renders Wallpaper Engine scene wallpapers using SpriteKit.
//  Follows the same ViewModel pattern as VideoWallpaperViewModel.
//

import SpriteKit
import SwiftUI
import AVFoundation
import Combine
import CoreText

class SceneWallpaperViewModel: ObservableObject, WallpaperPlaybackSession {
    private let screenId: String
    private var audioEnabled = true
    private var exportProperties: [String: Any]?
    private var preparingForDisplay = false
    private var preparationCancelled: () -> Bool = { false }
    var requestReload: (() -> Void)?
    private(set) var loadFailure: String?
    private static let preparationQueue = DispatchQueue(label: "com.openwallpaper.desktop-prepare", qos: .userInitiated)

    /// Own the unpublished renderer exclusively on this queue, then hand it to main.
    static func prepare(wallpaper: WEWallpaper, screenId: String, assets: URL?,
                        cancelled: @escaping () -> Bool) async throws -> SceneWallpaperViewModel {
        try await withCheckedThrowingContinuation { continuation in
            preparationQueue.async {
                if cancelled() { continuation.resume(throwing: CancellationError()); return }
                let model = autoreleasepool {
                    SceneWallpaperViewModel(wallpaper: wallpaper, screenId: screenId,
                        sharedAssets: { assets }, preparingForDisplay: true, cancelled: cancelled)
                }
                if cancelled() {
                    model.stop(); continuation.resume(throwing: CancellationError())
                } else if let failure = model.loadFailure {
                    model.stop()
                    continuation.resume(throwing: NSError(domain: "ScenePreparation", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: failure]))
                } else {
                    continuation.resume(returning: model)
                }
            }
        }
    }

    /// Called only after preparation completes, immediately before presenting the scene.
    func activatePreparedScene() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard preparingForDisplay else { return }
        preparingForDisplay = false; exportProperties = nil; preparationCancelled = { false }
        (skScene as? InteractiveWallpaperScene)?.activateLiveMedia()
        installLiveObservers()
        WallpaperPlaybackSessions.shared.register(self, screenId: screenId)
        volumeSubscription = AppDelegate.shared.wallpaperViewModel.volumePublisher(for: currentWallpaper)
            .sink { [weak self] volume in self?.playVolume = volume; self?.applyPlayback() }
        let directory = currentWallpaper.wallpaperDirectory.standardizedFileURL.path
        propertySubscription = NotificationCenter.default.publisher(for: ScenePropertyStore.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard notification.object as? String == directory,
                      let changes = notification.userInfo as? [String: Any] else { return }
                (self?.skScene as? InteractiveWallpaperScene)?.scriptRuntime?.applyUserProperties(changes)
            }
        (skScene as? InteractiveWallpaperScene)?.scriptRuntime?.applyUserProperties(
            ScenePropertyStore.shared.values(at: currentWallpaper.wallpaperDirectory))
        applyPlayback()
    }

    func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        applyPlayback()
    }
    static func log(_ msg: String) {
        let line = "[SceneVM] \(msg)"
        NSLog("%@", line)
    }

    var currentWallpaper: WEWallpaper {
        willSet {
            loadScene(from: newValue)
        }
    }

    @Published var skScene: SKScene?

    private var fontCache: [String: NSFont] = [:]
    private var textureCache: [String: NSImage] = [:]
    private var animationCache: [String: TEXAnimation] = [:]
    private var videoTextures: [String: SceneVideoTexture] = [:]
    private var pendingAnimations: [(SKSpriteNode, [SKTexture], [Double])] = []
    private(set) var renderingWarnings: [String] = []
    private var pkgParser: PKGParser?
    private var assetResolver: SceneAssetResolver?
    private let diagnosticID = UUID()
    private var isActive = false
    private let sharedAssets: () -> URL?
    private var rawObjects: [[String: Any]] = []
    private var spectrumSources: [SceneAudioSpectrumSource?] = []
    private var preparedBackgroundVideo: SceneVideoTexture?
    private var videoPlayer: AVQueuePlayer?
    private var videoLooper: AVPlayerLooper?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var readinessTimer: Timer?
    private var restartVideo: (() -> Void)?
    private var videoRecoveryAttempts = 0
    private weak var videoNode: SKVideoNode?
    private weak var videoPoster: SKSpriteNode?
    private var audioPlayers: [(AVAudioPlayer, Float)] = []
    private var temporaryDirectory: URL?
    private var cancellables = Set<AnyCancellable>()
    private var volumeSubscription: AnyCancellable?
    private var propertySubscription: AnyCancellable?
    private var audioError: String?
    private var sleeping = false
    private var sleepReasons = Set<String>()
    private var policyPaused = false
    private var policyMuted = false
    func setPlaybackPolicy(paused: Bool, muted: Bool) {
        policyPaused = paused; policyMuted = muted
        applyPlayback()
    }

    private var playRate: Float = 0
    private var playVolume: Float = 0
    private weak var fallbackNode: SKNode?
    private weak var errorNode: SKLabelNode?

    func stop() {
        isActive = false
        (skScene as? InteractiveWallpaperScene)?.stop()
        spectrumSources.forEach { $0?.stop() }; spectrumSources.removeAll()
        rawObjects.removeAll()
        if exportProperties == nil { WallpaperPlaybackSessions.shared.unregister(self, screenId: screenId) }
        volumeSubscription = nil
        propertySubscription = nil
        readinessTimer?.invalidate()
        readinessTimer = nil
        restartVideo = nil
        videoRecoveryAttempts = 0
        videoNode = nil
        videoPoster = nil
        videoPlayer?.pause()
        videoLooper?.disableLooping()
        videoPlayer?.removeAllItems()
        videoLooper = nil
        videoPlayer = nil
        preparedBackgroundVideo = nil
        videoOutput = nil
        audioPlayers.forEach { $0.0.stop() }
        audioPlayers.removeAll()
        skScene?.removeAllChildren()
        fontCache.removeAll()
        textureCache.removeAll()
        animationCache.removeAll(); pendingAnimations.removeAll()
        videoTextures.values.forEach { $0.stop() }; videoTextures.removeAll()
        renderingWarnings.removeAll()
        pkgParser = nil
        assetResolver = nil
        if exportProperties == nil { SceneAssetDiagnostics.shared.remove(diagnosticID) }
        if let directory = temporaryDirectory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Self.log("Temporary media cleanup failed: \(error)") }
        }
        temporaryDirectory = nil
        audioError = nil
    }

    private func applyPlayback() {
        let rate: Float = (sleeping || policyPaused) ? 0 : playRate
        videoPlayer?.rate = rate
        videoTextures.values.forEach { $0.player.rate = rate }
        videoPlayer?.volume = audioEnabled && !policyMuted ? playVolume : 0
        if let background = preparedBackgroundVideo {
            background.player.isMuted = !audioEnabled || policyMuted
            background.player.volume = audioEnabled && !policyMuted ? playVolume : 0
        }
        for (player, volume) in audioPlayers {
            player.volume = audioEnabled && !policyMuted ? volume * playVolume : 0
            if rate == 0 { player.pause() }
            else { player.rate = rate; if !player.isPlaying { player.play() } }
        }
        skScene?.isPaused = rate == 0
        (skScene as? InteractiveWallpaperScene)?.setVideoPlaybackRate(rate)
    }

    private func mediaURL(data: Data, extension ext: String) throws -> URL {
        if temporaryDirectory == nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WE-scene-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            temporaryDirectory = dir
        }
        let url = temporaryDirectory!.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func reportFailure(_ message: String) {
        loadFailure = message
        Self.log(message)
        errorNode?.text = message
        errorNode?.isHidden = false
        if let videoPoster { videoPoster.isHidden = false; fallbackNode?.isHidden = true }
        else { fallbackNode?.isHidden = false }
    }


    init(wallpaper: WEWallpaper, screenId: String = UUID().uuidString, sharedAssets: @escaping () -> URL? = { EngineAssetLibrary.standard.activeRoot }, exportProperties: [String: Any]? = nil, preparingForDisplay: Bool = false, cancelled: @escaping () -> Bool = { false }) {
        self.preparingForDisplay = preparingForDisplay
        self.preparationCancelled = cancelled
        self.exportProperties = preparingForDisplay ? [:] : exportProperties
        self.sharedAssets = sharedAssets
        self.screenId = screenId
        self.currentWallpaper = wallpaper
        Self.log("init: wallpaper=\(wallpaper.project.title ?? "?") dir=\(wallpaper.wallpaperDirectory.path)")
        if self.exportProperties != nil {
            audioEnabled = false; playRate = preparingForDisplay ? 0 : 1; playVolume = 0
            loadScene(from: wallpaper)
            return
        }
        installLiveObservers()
        loadScene(from: wallpaper)
    }

    private func installLiveObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        let shared = AppDelegate.shared.wallpaperViewModel
        playRate = shared.playRate
        playVolume = shared.playVolume
        shared.$playRate.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.playRate = value
            self?.applyPlayback()
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: EngineAssetLibrary.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isActive else { return }
                if let requestReload = self.requestReload { requestReload() }
                else { self.loadScene(from: self.currentWallpaper) }
            }.store(in: &cancellables)
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Scene Loading

    func loadScene(from wallpaper: WEWallpaper) {
        stop()
        loadFailure = nil
        isActive = true
        if exportProperties == nil {
            WallpaperPlaybackSessions.shared.register(self, screenId: screenId)
            volumeSubscription = AppDelegate.shared.wallpaperViewModel.volumePublisher(for: wallpaper)
                .sink { [weak self] volume in
                    self?.playVolume = volume
                    self?.applyPlayback()
                }
        }
        let dir = SceneAssetResolver.contentRoot(wallpaper.wallpaperDirectory)
        let sceneFile = wallpaper.project.file  // e.g. "scene.json" or "gifscene.json"

        // Derive PKG name from scene file: "scene.json" → "scene.pkg", "gifscene.json" → "gifscene.pkg"
        let pkgName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let pkgURL = dir.appending(path: pkgName)
        var scene: WEScene?
        var loadError = "Scene file not found: " + sceneFile
        var packageError: String?
        if FileManager.default.fileExists(atPath: pkgURL.path) {
            do { pkgParser = try PKGParser(url: pkgURL) }
            catch { loadError = error.localizedDescription; packageError = loadError }
        }
        let resolver = SceneAssetResolver(wallpaperRoot: dir, package: pkgParser, sharedRoot: sharedAssets())
        assetResolver = resolver
        resolver.didReport = { [weak self] issues in
            guard let self, self.exportProperties == nil else { return }
            SceneAssetDiagnostics.shared.update(self.diagnosticID,
                wallpaper: wallpaper.project.title ?? dir.lastPathComponent, issues: issues)
        }
        if let packageError { resolver.report(.invalid, pkgName, packageError) }
        if let data = resolver.data(sceneFile, required: true) {
            do { scene = try WEScene.decode(data: data, projectData: resolver.data("project.json")) }
            catch {
                loadError = error.localizedDescription
                resolver.report(.invalid, sceneFile, loadError)
            }
        }

        guard let scene = scene else {
            let fallback = SKScene(size: CGSize(width: 1920, height: 1080))
            fallback.scaleMode = .aspectFill
            addFallback(to: fallback, wallpaperDir: dir)
            skScene = fallback
            reportFailure("Unable to load scene: " + loadError)
            return
        }

        if let data = assetData(sceneFile, wallpaperDir: dir),
           let raw = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
            rawObjects = raw["objects"] as? [[String:Any]] ?? []
        }
        Self.log("Scene loaded: \(scene.objects.count) objects from \(sceneFile)")
        let skScene = buildSKScene(from: scene, wallpaperDir: dir)
        Self.log("SKScene built: \(skScene.children.count) children")
        self.skScene = skScene
        if exportProperties == nil || preparingForDisplay { loadAudio(from: scene, wallpaperDir: dir) }
        applyPlayback()
    }

    // MARK: - SpriteKit Scene Building

    private func buildSKScene(from scene: WEScene, wallpaperDir: URL) -> SKScene {
        let projection = scene.general.orthogonalprojection ?? WEOrthogonalProjection(width: 1920, height: 1080)
        let skScene = InteractiveWallpaperScene(size: CGSize(width: projection.width, height: projection.height))
        skScene.scaleMode = .aspectFill

        let camera = SKCameraNode()
        camera.position = CGPoint(x: skScene.size.width / 2, y: skScene.size.height / 2)
        let zoom = scene.general.zoom ?? 1
        camera.setScale(zoom.isFinite && zoom > 0 ? 1 / zoom : 1)
        skScene.addChild(camera)
        skScene.camera = camera

        // Background color from clearcolor
        if let colorStr = scene.general.clearcolor {
            let c = colorStr.parseColor()
            skScene.backgroundColor = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
        }

        addFallback(to: skScene, wallpaperDir: wallpaperDir)
        // Keep transform-only and hidden objects: children still need their parent chain.
        let containers = scene.objects.map { object -> SKNode in
            let node = SKNode()
            node.name = "layer:" + String(object.id ?? -1)
            let p = (object.origin ?? "0 0 0").parseVector3()
            let scale = (object.scale ?? "1 1 1").parseVector3()
            node.position = CGPoint(x: p.0, y: p.1)
            node.xScale = scale.0; node.yScale = scale.1
            node.zRotation = (object.angles ?? "0 0 0").parseVector3().2 * .pi / 180
            node.isHidden = object.visible == false
            return node
        }
        var indices: [Int: Int] = [:]
        for (i, object) in scene.objects.enumerated() {
            if let id = object.id {
                if indices[id] != nil { warn("Duplicate layer ID: \(id)") }
                else { indices[id] = i }
            }
        }
        for (i, object) in scene.objects.enumerated() {
            var seen: Set<Int> = [i]
            var ancestor = object.parent.flatMap { indices[$0] }
            var cycle = false
            while let a = ancestor {
                if !seen.insert(a).inserted { cycle = true; break }
                ancestor = scene.objects[a].parent.flatMap { indices[$0] }
            }
            if let parent = object.parent.flatMap({ indices[$0] }), !cycle {
                containers[parent].addChild(containers[i])
            } else {
                skScene.addChild(containers[i])
                if object.parent != nil { warn("Missing or cyclic parent for \(object.name ?? "layer")") }
            }
        }
        func visible(_ node: SKNode) -> Bool {
            var cursor: SKNode? = node
            while let current = cursor { if current.isHidden { return false }; cursor = current.parent }
            return true
        }
        // Scene order is paint order: the first drawable, visible image is the
        // background. Large composition containers and foreground effects are
        // not backgrounds merely because their exported bounds are larger.
        var backgroundIndex: Int?
        var backgroundImage: SKSpriteNode?
        for index in scene.objects.indices {
            if preparationCancelled() { break }
            guard scene.objects[index].image != nil, visible(containers[index]),
                  let image = buildImageNode(scene.objects[index], wallpaperDir: wallpaperDir) else { continue }
            backgroundIndex = index
            backgroundImage = image
            break
        }
        for (index, object) in scene.objects.enumerated() {
            if preparationCancelled() { break }
            let holder = containers[index]
            if exportProperties == nil && index == backgroundIndex && buildVideoNode(object, in: skScene, wallpaperDir: wallpaperDir) {
                if let video = videoNode {
                    video.removeFromParent(); video.position = .zero
                    video.xScale = 1; video.yScale = 1; video.zRotation = 0
                    video.zPosition = CGFloat(index + 1)
                    holder.addChild(video)
                    if let poster = videoPoster {
                        poster.removeFromParent(); poster.position = .zero
                        poster.xScale = 1; poster.yScale = 1; poster.zRotation = 0
                        poster.zPosition = video.zPosition - 0.01
                        holder.addChild(poster)
                    }
                }
            } else if let image = index == backgroundIndex ? backgroundImage : buildImageNode(object, wallpaperDir: wallpaperDir) {
                if preparingForDisplay && index == backgroundIndex {
                    preparedBackgroundVideo = image.userData?["videoTexture"] as? SceneVideoTexture
                }
                image.position = .zero
                image.zPosition = CGFloat(index + 1)
                holder.addChild(image)
                if index == backgroundIndex { fallbackNode?.isHidden = true }
            } else if let path = object.particle {
                if let system = buildSpriteParticles(path: path, overrides: rawObjects[index]["instanceoverride"] as? [String: Any] ?? [:], wallpaperDir: wallpaperDir) {
                    system.zPosition = CGFloat(index + 1)
                    holder.addChild(system); skScene.bindParticles(system); system.prewarm()
                } else if let particle: WEParticleSystem = loadJSON(path: path, wallpaperDir: wallpaperDir),
                   particle.renderer?.contains(where: { $0.name == "rope" }) != true {
                    warn("Unsupported particle renderer: " + path)
                }
            } else if object.text != nil {
                let text = buildTextNode(object, wallpaperDir: wallpaperDir)
                text.zPosition = CGFloat(index + 1); holder.addChild(text)
            } else if index == backgroundIndex {
                reportFailure("Background unavailable: " + (object.name ?? object.image ?? "unknown"))
            }
        }
        if backgroundIndex == nil { reportFailure("Scene contains no supported background") }
        // Orthographic export coordinates are canvas coordinates; camera.eye/center are
        // editor navigation state, not a runtime offset for these 2D scene exports.
        let nodes = Dictionary(uniqueKeysWithValues: indices.map { ($0.key, containers[$0.value]) })
        let contentNodes = nodes.compactMapValues { $0.children.first { $0 is SKSpriteNode || $0 is SKLabelNode || $0 is SKVideoNode } }
        let properties = ScenePropertyStore.shared.values(at: currentWallpaper.wallpaperDirectory).merging(exportProperties ?? [:]) { _, override in override }
        skScene.install(objects:rawObjects,nodes:nodes,contentNodes:contentNodes,properties:properties,
                        storageKey:currentWallpaper.wallpaperDirectory.standardizedFileURL.path, offline: exportProperties != nil) { [weak self] path in
            self?.assetResolver?.data(path, required: true)
        }
        let propertyDirectory = currentWallpaper.wallpaperDirectory
        if exportProperties == nil {
            propertySubscription = NotificationCenter.default.publisher(for: ScenePropertyStore.didChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak skScene] notification in
                    guard notification.object as? String == propertyDirectory.standardizedFileURL.path,
                          let changes = notification.userInfo as? [String: Any] else { return }
                    skScene?.scriptRuntime?.applyUserProperties(changes)
                }
        }
        for (node, textures, durations) in pendingAnimations {
            skScene.bindTextureAnimation(node: node, textures: textures, durations: durations)
        }
        pendingAnimations.removeAll()
        skScene.effectsDidUpdate = { id, effects in
            guard let sprite = contentNodes[id] as? SKSpriteNode else { return }
            Self.updateEffectUniforms(sprite,effects:effects)
        }
        skScene.scriptRuntime?.applyUserProperties(properties)
        skScene.spectrumProvider = { [weak self] in
            guard let self else { return Array(repeating:0,count:64) }
            var mixed = [Float](repeating:0,count:64)
            for (index,source) in self.spectrumSources.enumerated() where index < self.audioPlayers.count {
                let player = self.audioPlayers[index].0
                let bins = source?.snapshot(at:player.currentTime,volume:player.volume,playing:player.isPlaying) ?? Array(repeating:0,count:64)
                for i in 0..<64 { mixed[i] = min(1,mixed[i]+bins[i]) }
            }
            if self.exportProperties != nil {
                return DispatchQueue.main.sync { ExternalMediaService.shared.spectrum(wallpaper: mixed) }
            }
            return ExternalMediaService.shared.spectrum(wallpaper: mixed)
        }
        return skScene
    }

    private func addFallback(to scene: SKScene, wallpaperDir: URL) {
        let node = SKSpriteNode(texture: loadPreviewImage(wallpaperDir: wallpaperDir).map(SKTexture.init(image:)))
        node.size = scene.size
        node.position = CGPoint(x: scene.size.width / 2, y: scene.size.height / 2)
        node.zPosition = 1_000_000
        node.color = .black
        scene.addChild(node)
        fallbackNode = node
        let label = SKLabelNode(fontNamed: "Helvetica")
        label.fontSize = 20
        label.fontColor = .white
        label.position = CGPoint(x: scene.size.width / 2, y: 40)
        label.zPosition = 1_000_001
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = scene.size.width - 80
        label.isHidden = true
        scene.addChild(label)
        errorNode = label
    }

    private func assetData(_ path: String, wallpaperDir: URL) -> Data? {
        assetResolver?.data(path)
    }

    private func buildVideoNode(_ object: WESceneObject, in scene: SKScene, wallpaperDir: URL) -> Bool {
        guard let modelPath = object.image,
              let model: WEModel = loadJSON(path: modelPath, wallpaperDir: wallpaperDir),
              let materialPath = model.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir),
              let name = material.passes?.first?.textures?.first ?? nil else { return false }
        guard let asset = assetResolver?.asset(candidates: textureCandidates(name: name, materialPath: materialPath)),
              asset.path.lowercased().hasSuffix(".tex"),
              let video = TEXParser(data: asset.data).extractVideoData() else { return false }
        do {
            let url = try mediaURL(data: video, extension: "mp4")
            restartVideo = { [weak self, weak scene] in
                guard let self, let scene else { return }
                self.installVideo(object, url: url, in: scene)
            }
            installVideo(object, url: url, in: scene)
        } catch { reportFailure("Video extraction failed: " + error.localizedDescription) }
        return true
    }

    /// Rebuild failed AVFoundation objects without reloading scripts or music.
    @discardableResult
    func recoverBackgroundPlayback() -> Bool {
        guard !sleeping, !policyPaused, playRate != 0, videoRecoveryAttempts < 3,
              let restartVideo else { return false }
        videoRecoveryAttempts += 1
        Self.log("Rebuilding background player (attempt \(videoRecoveryAttempts)/3)")
        restartVideo()
        applyPlayback()
        return true
    }

    private func installVideo(_ object: WESceneObject, url: URL, in scene: SKScene) {
        readinessTimer?.invalidate()
        videoPlayer?.pause()
        videoLooper?.disableLooping()
        videoPlayer?.removeAllItems()
        videoOutput = nil
        let previousNode = videoNode
        let previousParent = previousNode?.parent
        previousNode?.removeFromParent()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        videoPlayer = player
        videoLooper = AVPlayerLooper(player: player, templateItem: item)
        let node = SKVideoNode(avPlayer: player)
        let size = (object.size ?? "1920 1080").parseVector2()
        node.size = CGSize(width: size.0, height: size.1)
        let origin = (object.origin ?? "960 540 0").parseVector3()
        node.position = CGPoint(x: origin.0, y: origin.1)
        let scale = (object.scale ?? "1 1 1").parseVector3()
        node.xScale = scale.0
        node.yScale = scale.1
        node.zRotation = (object.angles ?? "0 0 0").parseVector3().2 * .pi / 180
        node.alpha = object.alpha ?? 1
        node.isHidden = true
        if let previousNode, let previousParent {
            node.position = previousNode.position
            node.xScale = previousNode.xScale; node.yScale = previousNode.yScale
            node.zRotation = previousNode.zRotation; node.zPosition = previousNode.zPosition
            node.alpha = previousNode.alpha
            previousParent.addChild(node)
            if let id = object.id {
                (scene as? InteractiveWallpaperScene)?.scriptRuntime?.replaceContentNode(id: id, with: node)
            }
        } else { scene.addChild(node) }
        videoNode = node
        // A low-resolution workshop preview must not remain the desktop while
        // playback is paused or the queue is still preparing its first frame.
        if videoPoster == nil {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            if let image = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                let poster = SKSpriteNode(texture: SKTexture(cgImage: image))
                poster.name = "background-video-poster"
                poster.size = node.size; poster.position = node.position
                poster.xScale = node.xScale; poster.yScale = node.yScale
                poster.zRotation = node.zRotation; poster.alpha = node.alpha
                poster.zPosition = node.zPosition - 0.01
                (node.parent ?? scene).addChild(poster)
                videoPoster = poster
                fallbackNode?.isHidden = true
            }
        }
        var elapsed = 0.0
        var healthyTime = 0.0
        var hasFrame = false
        var reportedFailure = false
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak node] timer in
            guard let self, let player = self.videoPlayer else { timer.invalidate(); return }
            let failed = player.status == .failed || player.currentItem?.status == .failed || self.videoLooper?.status == .failed
            let emptyQueue = hasFrame && player.items().isEmpty
            if reportedFailure || failed || emptyQueue || (!hasFrame && elapsed >= 15) {
                if !reportedFailure {
                    let error = (player.currentItem?.error ?? player.error ?? self.videoLooper?.error) as NSError?
                    let detail = error.map { "\($0.domain) (\($0.code)): \($0.localizedDescription)" }
                        ?? (emptyQueue ? "Background video queue became empty" : "Background video has not produced a frame")
                    Self.log("Background failure details: \(String(describing: error)); item log: \(String(describing: player.currentItem?.errorLog()?.events))")
                    self.reportFailure("Background playback failed: " + detail)
                    node?.isHidden = true
                    player.pause()
                    reportedFailure = true
                    elapsed = 0
                }
                // Leave the monitor alive while paused/asleep so resume/wake can
                // retry. Backoff and a finite budget prevent corrupt-file loops.
                if !self.sleeping && !self.policyPaused && self.playRate != 0 {
                    elapsed += 0.1
                    if elapsed >= pow(2, Double(self.videoRecoveryAttempts)) {
                        _ = self.recoverBackgroundPlayback()
                    }
                }
                return
            }
            guard !self.sleeping, !self.policyPaused, self.playRate != 0 else { return }
            if hasFrame {
                healthyTime += 0.1
                if healthyTime >= 60 { self.videoRecoveryAttempts = 0 }
                return
            }
            elapsed += 0.1
            guard let current = player.currentItem else { return }
            if self.videoOutput == nil || !current.outputs.contains(where: { $0 === self.videoOutput }) {
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                current.add(output)
                self.videoOutput = output
            }
            if let output = self.videoOutput,
               output.copyPixelBuffer(forItemTime: current.currentTime(), itemTimeForDisplay: nil) != nil {
                node?.isHidden = false
                self.videoPoster?.isHidden = true
                self.fallbackNode?.isHidden = true
                self.errorNode?.text = self.audioError
                self.errorNode?.isHidden = self.audioError == nil
                hasFrame = true
                current.remove(output)
                self.videoOutput = nil
            }
        }
    }

    private func loadAudio(from scene: WEScene, wallpaperDir: URL) {
        for object in scene.objects where object.visible != false && object.startsilent != true {
            if preparationCancelled() { break }
            guard let path = object.sound?.first else { continue }
            do {
                guard let data = assetResolver?.data(path, required: true) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let url = try mediaURL(data: data, extension: (path as NSString).pathExtension)
                let source = try? SceneAudioSpectrumSource(url:url)
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = object.playbackmode == "loop" ? -1 : 0
                player.enableRate = true
                player.prepareToPlay()
                spectrumSources.append(source)
                audioPlayers.append((player, Float(min(1, max(0, object.volume ?? 1)))))
            } catch {
                let message = "Audio unavailable (" + path + "): " + error.localizedDescription
                audioError = message
                Self.log(message)
                errorNode?.text = message
                errorNode?.isHidden = false
            }
        }
        // Video soundtrack and scene sounds are mixed, each with its own timeline.
        // Global volume/mute affects both; a video loop never restarts background music.
    }

    private func loadPreviewImage(wallpaperDir: URL) -> NSImage? {
        for name in ["preview.jpg", "preview.png", "preview.gif"] {
            let url = wallpaperDir.appending(path: name)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    // MARK: - Image Objects

    private func buildImageNode(_ obj: WESceneObject, wallpaperDir: URL) -> SKSpriteNode? {
        guard let imagePath = obj.image else { return nil }

        let model: WEModel? = loadJSON(path: imagePath, wallpaperDir: wallpaperDir)
        let materialPath = model?.material ?? (imagePath == "models/util/solidlayer.json" ? "materials/util/solidlayer.json" : "")
        let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
        // These generators replace their input completely (style 3 uses black as
        // the neutral screen-blend background), so no framebuffer copy is needed.
        let generatorPaths = ["effects/workshop/3444196917/_________________________________/effect.json", "effects/workshop/3782665413/highly_customizable_audio_visualizer/effect.json"]
        let generatedAudio = imagePath == "models/util/composelayer.json" && obj.effects?.first.map { generatorPaths.contains($0.file) } == true
        let textureName = generatedAudio ? "util/white" : (obj.instance?.textures?.first ?? nil)
            ?? (material?.passes?.first?.textures?.first ?? nil)
            ?? (materialPath.hasPrefix("materials/util/solidlayer") ? "util/white" : nil)
        let binding = (obj.instance?.usertextures ?? material?.passes?.first?.usertextures)?.first?.string
        let properties = ScenePropertyStore.shared.values(at: currentWallpaper.wallpaperDirectory).merging(exportProperties ?? [:]) { _, new in new }
        let customPath = binding.flatMap { properties[$0] as? String }
        let customData = customPath.flatMap { path -> Data? in
            guard !path.isEmpty else { return nil }
            if path.hasPrefix("/") { return try? Data(contentsOf: URL(fileURLWithPath: path)) }
            return assetResolver?.data(path, required: true)
        }
        let customSource = customData.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        guard let textureName = textureName,
              let image = customData.flatMap({ NSImage(data: $0) })
                ?? loadTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir) else {
            warn("Missing image material/texture: " + imagePath)
            return nil
        }
        var texture = SKTexture(image: image)
        let animation = customSource == nil ? animationCache[materialPath + "|" + textureName] : nil
        var frames: [SKTexture] = []
        if let animation {
            let filtering: SKTextureFilteringMode = animation.nearestFiltering ? .nearest : .linear
            let atlases = animation.images.map { image -> SKTexture in
                let atlas = SKTexture(image: image); atlas.filteringMode = filtering; return atlas
            }
            frames = animation.frames.map { frame in
                let texture = SKTexture(rect: frame.rect, in: atlases[frame.imageIndex])
                texture.filteringMode = filtering
                return texture
            }
            if let first = frames.first { texture = first }
        }
        if let path = model?.puppet {
            do {
                guard let data = assetResolver?.data(path, required: true) else { throw MDLParser.Failure.invalid("missing model") }
                let puppet = try MDLParser.parse(data)
                let dimensions = (obj.size ?? "\(image.size.width) \(image.size.height)").parseVector2()
                guard dimensions.0.isFinite, dimensions.1.isFinite,
                      dimensions.0 > 0, dimensions.1 > 0, dimensions.0 <= 8192, dimensions.1 <= 8192 else {
                    throw MDLParser.Failure.invalid("viewport size")
                }
                let layers = rawObjects.first { $0["id"] as? Int == obj.id }?["animationlayers"] as? [[String: Any]] ?? []
                return ScenePuppetNode(model: puppet, image: image, size: CGSize(width: dimensions.0, height: dimensions.1), layers: layers)
            } catch {
                warn("Unsupported puppet \(path): \(error)")
                return nil
            }
        }
        var customFrames: [SKTexture] = [], customDurations: [Double] = []
        if let source = customSource {
            for index in 0..<CGImageSourceGetCount(source) {
                guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                customFrames.append(SKTexture(cgImage: frame))
                let info = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = info?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let duration = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                    ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
                customDurations.append(duration > 0.01 ? duration : 0.1)
            }
            if let first = customFrames.first { texture = first }
        }
        let node = SKSpriteNode(texture: texture)
        if !customFrames.isEmpty {
            node.userData = NSMutableDictionary()
            node.userData?["presetTexture"] = customPath
            if customFrames.count > 1 { pendingAnimations.append((node, customFrames, customDurations)) }
        }
        if customSource == nil, let video = videoTextures[materialPath + "|" + textureName] {
            node.userData = NSMutableDictionary(); node.userData?["videoTexture"] = video
        }
        if let animation, !frames.isEmpty {
            pendingAnimations.append((node, frames, animation.frames.map(\.duration)))
        }

        // Size from object, or use pixel dimensions (not point size, which is halved on Retina)
        if let sizeStr = obj.size {
            let (w, h) = sizeStr.parseVector2()
            node.size = CGSize(width: w, height: h)
        } else if let firstFrame = animation?.frames.first {
            node.size = firstFrame.size
        } else {
            let pixelW = image.representations.first?.pixelsWide ?? Int(image.size.width)
            let pixelH = image.representations.first?.pixelsHigh ?? Int(image.size.height)
            node.size = CGSize(width: pixelW, height: pixelH)
        }

        // Position: WE uses top-left origin with Y-down, SpriteKit uses bottom-left with Y-up
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            node.position = CGPoint(x: x, y: y)
        }

        // Alpha
        node.alpha = CGFloat(obj.alpha ?? 1.0)

        // Color tint
        if let colorStr = obj.color {
            let c = colorStr.parseColor()
            node.color = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
            node.colorBlendFactor = 1.0
        }

        // Blend mode from material
        if let blending = material?.passes?.first?.blending {
            switch blending {
            case "additive": node.blendMode = .add
            case "translucent": node.blendMode = .alpha
            default: node.blendMode = .alpha
            }
        }

        node.anchorPoint = anchorPoint(obj.alignment)
        // These are layer blend modes, not tint enable flags.
        if obj.colorBlendMode == 6 { node.blendMode = .add }
        if obj.colorBlendMode == 31 { node.blendMode = .screen }
        applyEffects(obj, to: node, wallpaperDir: wallpaperDir)
        if (obj.instance?.usertextures != nil ? obj.instance?.usesMediaThumbnail : material?.passes?.first?.usesMediaThumbnail) == true {
            node.userData = node.userData ?? NSMutableDictionary()
            node.userData?["mediaThumbnail"] = true
        }
        return node
    }

    private func warn(_ message: String) {
        if !renderingWarnings.contains(message) { renderingWarnings.append(message); Self.log(message) }
        if message.hasPrefix("Unsupported") || message.hasPrefix("Unknown built-in") {
            assetResolver?.report(.unsupported, message, "The renderer does not support this feature yet")
        } else if message.hasPrefix("Approximate") {
            assetResolver?.report(.approximate, message, "Using a generated substitute")
        }
    }

    private func anchorPoint(_ alignment: String?) -> CGPoint {
        let alignment = alignment ?? "center"
        return CGPoint(x: alignment.contains("left") ? 0 : alignment.contains("right") ? 1 : 0.5,
                       y: alignment.contains("bottom") ? 0 : alignment.contains("top") ? 1 : 0.5)
    }

    private func buildTextNode(_ object: WESceneObject, wallpaperDir: URL) -> SKLabelNode {
        var font = NSFont.systemFont(ofSize: object.pointsize ?? 24)
        if let path = object.font {
            if path.hasPrefix("systemfont_") {
                font = NSFont(name: String(path.dropFirst("systemfont_".count)), size: 24) ?? NSFont.systemFont(ofSize: 24)
            } else if let cached = fontCache[path] { font = cached }
            else if let bytes = assetResolver?.data(path, required: true),
                    let provider = CGDataProvider(data: bytes as CFData), let cgFont = CGFont(provider) {
                // An in-memory font avoids global registration conflicts across displays.
                font = CTFontCreateWithGraphicsFont(cgFont, 24, nil, nil) as NSFont
                fontCache[path] = font
            } else { warn("Unable to load font: " + path) }
        }
        // This scene export uses a 300-DPI text raster: its saved text heights
        // (140, 134, 61) match the packaged font metrics at 300 / 72.
        // Do not use the Mac display's backing scale: parent transforms apply later.
        font = NSFont(descriptor: font.fontDescriptor, size: (object.pointsize ?? 24) * 300 / 72) ?? font
        let c = (object.color ?? "1 1 1").parseColor()
        let size = (object.size ?? "0 0").parseVector2()
        let padding = (object.padding ?? "0 0").parseVector2()
        let raw = rawObjects.first { $0["id"] as? Int == object.id } ?? [:]
        let maxWidth = (raw["limitwidth"] as? Bool == true) ? (raw["maxwidth"] as? NSNumber).map { CGFloat($0.doubleValue) } : nil
        let maxRows = (raw["limitrows"] as? Bool == true) ? (raw["maxrows"] as? Int ?? 1) : 0
        let node = SceneTextNode(text: object.text ?? "", font: font,
                                 color: NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1),
                                 size: CGSize(width: size.0, height: size.1),
                                 padding: CGSize(width: padding.0, height: padding.1),
                                 horizontal: object.horizontalalign ?? "center",
                                 vertical: object.verticalalign ?? "center", maxWidth: maxWidth, maxRows: maxRows,
                                 ellipsis: raw["limituseellipsis"] as? Bool == true)
        node.alpha = object.alpha ?? 1
        return node
    }

    // MARK: - Particle Objects

    private func buildSpriteParticles(path: String, overrides: [String: Any], wallpaperDir: URL, depth: Int = 0) -> SceneSpriteParticles? {
        guard depth < 2, let data = assetResolver?.data(path, required: true),
              let definition = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let renderers = definition["renderer"] as? [[String: Any]],
              !renderers.isEmpty, renderers.allSatisfy({ ["sprite", "spritetrail"].contains($0["name"] as? String ?? "") }),
              let materialPath = definition["material"] as? String,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir),
              let name = material.passes?.first?.textures?.first ?? nil,
              let image = loadTexture(named: name, materialDir: materialPath, wallpaperDir: wallpaperDir) else { return nil }
        var textures = [SKTexture(image: image)]
        if let animation = animationCache[materialPath + "|" + name] {
            let atlases = animation.images.map(SKTexture.init(image:))
            textures = animation.frames.map { SKTexture(rect: $0.rect, in: atlases[$0.imageIndex]) }
        }
        let children = definition["children"] as? [[String: Any]] ?? []
        // Texture loading is cached. A per-parent child simulation preserves eventfollow trails.
        let system = SceneSpriteParticles(definition: definition, textures: textures,
            additive: material.passes?.first?.blending == "additive", overrides: overrides,
            children: children.isEmpty ? nil : { [weak self] in
                children.compactMap { child in
                    guard child["type"] as? String == "eventfollow", let path = child["name"] as? String else { return nil }
                    return self?.buildSpriteParticles(path: path, overrides: overrides, wallpaperDir: wallpaperDir, depth: depth+1)
                }
            })
        assetResolver?.report(.approximate, path, "2D sprite particle simulation; turbulence, sequence mapping and trail motion may differ from Wallpaper Engine")
        return system
    }

    private func buildParticleNode(_ obj: WESceneObject, wallpaperDir: URL, sceneSize: CGSize) -> SKNode? {
        guard let particlePath = obj.particle else { return nil }

        let particleSystem: WEParticleSystem? = loadJSON(path: particlePath, wallpaperDir: wallpaperDir)
        guard let ps = particleSystem else {
            print("[SceneVM] Failed to load particle system '\(particlePath)'")
            return nil
        }

        let emitter = SKEmitterNode()

        // Particle texture from material
        if let materialPath = ps.material {
            let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
            if let texName = material?.passes?.first?.textures?.first ?? nil {
                let texImage = loadTexture(named: texName, materialDir: materialPath, wallpaperDir: wallpaperDir)
                    ?? generateProceduralTexture(named: texName)
                if let img = texImage {
                    emitter.particleTexture = SKTexture(image: img)
                }
            }

            // Blend mode
            if let blending = material?.passes?.first?.blending {
                emitter.particleBlendMode = blending == "additive" ? .add : .alpha
            }
        }

        // Emitter properties
        if let em = ps.emitter?.first {
            emitter.particleBirthRate = CGFloat(em.rate ?? 100)

            // Apply instance override rate
            if let overrideRate = obj.instanceoverride?.rate?.value {
                emitter.particleBirthRate *= CGFloat(overrideRate)
            }

            // Emission area from distancemax (sphererandom emitter)
            if em.name == "sphererandom" {
                let dist = CGFloat(em.distancemax ?? 100)
                emitter.particlePositionRange = CGVector(dx: dist * 2, dy: dist * 2)
            }
        }

        // Initializers
        for ini in ps.initializer ?? [] {
            switch ini.name {
            case "lifetimerandom":
                let minLife = ini.min?.doubleValue ?? 1
                let maxLife = ini.max?.doubleValue ?? 1
                emitter.particleLifetime = CGFloat((minLife + maxLife) / 2)
                emitter.particleLifetimeRange = CGFloat(maxLife - minLife)

            case "sizerandom":
                let minSize = ini.min?.doubleValue ?? 1
                let maxSize = ini.max?.doubleValue ?? 1
                let avgSize = (minSize + maxSize) / 2
                // Apply instance override size
                let sizeMultiplier = obj.instanceoverride?.size ?? 1.0
                emitter.particleSize = CGSize(width: avgSize * sizeMultiplier, height: avgSize * sizeMultiplier)
                emitter.particleScaleRange = CGFloat((maxSize - minSize) / avgSize) * CGFloat(sizeMultiplier)

            case "velocityrandom":
                let minV = ini.min?.vectorValue ?? (0, 0, 0)
                let maxV = ini.max?.vectorValue ?? (0, 0, 0)
                // Use Y component for speed (primary direction in most WE particles)
                let avgSpeedY = (minV.1 + maxV.1) / 2
                let avgSpeedX = (minV.0 + maxV.0) / 2
                let speed = sqrt(avgSpeedX * avgSpeedX + avgSpeedY * avgSpeedY)
                emitter.particleSpeed = CGFloat(speed)
                emitter.particleSpeedRange = CGFloat(abs(maxV.1 - minV.1) / 2)
                // Emission angle: atan2 of velocity direction
                if speed > 0 {
                    // SpriteKit Y is up, WE Y is down for velocity
                    emitter.emissionAngle = CGFloat(atan2(-avgSpeedY, avgSpeedX))
                    emitter.emissionAngleRange = 0.1
                }

            case "alpharandom":
                let minA = ini.min?.doubleValue ?? 1
                let maxA = ini.max?.doubleValue ?? 1
                emitter.particleAlpha = CGFloat((minA + maxA) / 2)
                emitter.particleAlphaRange = CGFloat(maxA - minA)

            case "colorrandom":
                if let maxColor = ini.max?.vectorValue {
                    // Colors in WE particles are 0-255
                    emitter.particleColor = NSColor(
                        red: maxColor.0 / 255.0,
                        green: maxColor.1 / 255.0,
                        blue: maxColor.2 / 255.0,
                        alpha: 1.0)
                }

            default:
                break
            }
        }

        // Operators
        for op in ps.operator ?? [] {
            switch op.name {
            case "movement":
                if let gravityStr = op.gravity {
                    let (gx, gy, gz) = gravityStr.parseVector3()
                    // WE Z-axis maps to SpriteKit Y acceleration (WE uses Z for depth/vertical)
                    emitter.xAcceleration = CGFloat(gx)
                    // In WE, positive Z gravity pulls "forward", map to Y-down in SK
                    emitter.yAcceleration = CGFloat(-gz)
                    if gy != 0 && gz == 0 {
                        emitter.yAcceleration = CGFloat(-gy)
                    }
                }

            case "alphafade":
                // Fade in/out over lifetime
                let fadeIn = op.fadeintime ?? 0
                let fadeOut = op.fadeouttime ?? 1
                // SpriteKit particleAlphaSpeed: rate of alpha change per second
                // Approximate: particles fade in quickly and fade out over remaining lifetime
                if fadeOut < 1.0 {
                    emitter.particleAlphaSpeed = CGFloat(-1.0 / max(emitter.particleLifetime * CGFloat(1 - fadeOut), 0.1))
                }
                _ = fadeIn // Used implicitly through initial alpha ramp

            default:
                break
            }
        }

        // Renderer: spritetrail gets elongated aspect ratio
        if let renderer = ps.renderer?.first, renderer.name == "spritetrail" {
            let trailLength = CGFloat(renderer.maxlength ?? 50)
            emitter.particleSize = CGSize(width: 2, height: trailLength)
            // Align particles to movement direction
            emitter.particleRotation = emitter.emissionAngle
        }

        // Position from object origin
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            emitter.position = CGPoint(x: x, y: y)
        }

        // Scale from object
        if let scaleStr = obj.scale {
            let (sx, sy, _) = scaleStr.parseVector3()
            emitter.xScale = CGFloat(sx)
            emitter.yScale = CGFloat(sy)
        }

        // Max particles
        emitter.numParticlesToEmit = 0 // infinite

        return emitter
    }

    // MARK: - Asset Loading

    private func loadJSON<T: Decodable>(path: String, wallpaperDir: URL) -> T? {
        guard !path.isEmpty, let data = assetResolver?.data(path, required: true) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            assetResolver?.report(.invalid, path, "Invalid or unsupported JSON: " + error.localizedDescription)
            return nil
        }
    }

    private func textureCandidates(name: String, materialPath: String) -> [String] {
        let materialPath = materialPath.replacingOccurrences(of: "\\", with: "/")
        let directory = (materialPath as NSString).deletingLastPathComponent
        let bases = [directory.isEmpty ? name : directory + "/" + name, "materials/" + name, name]
        var candidates = bases.map { $0 + ".tex" } + bases
        for ext in ["png", "jpg", "jpeg", "gif"] { candidates += bases.map { $0 + "." + ext } }
        return candidates
    }

    private func loadTexture(named name: String, materialDir: String, wallpaperDir: URL) -> NSImage? {
        let cacheKey = materialDir + "|" + name
        if let cached = textureCache[cacheKey] { return cached }
        if name.split(separator: "/").last?.hasPrefix("_rt_") == true {
            assetResolver?.report(.unsupported, name, "Runtime render target requires a framebuffer pass; it is not a downloadable file")
            return nil
        }
        let candidates = textureCandidates(name: name, materialPath: materialDir)
        if let asset = assetResolver?.asset(candidates: candidates) {
            if asset.path.lowercased().hasSuffix(".tex") {
                let parser = TEXParser(data: asset.data)
                if let data = parser.extractVideoData() {
                    do {
                        let video = try SceneVideoTexture(url: mediaURL(data: data, extension: "mp4"))
                        videoTextures[cacheKey] = video; textureCache[cacheKey] = video.poster
                        return video.poster
                    } catch {
                        assetResolver?.report(.invalid, asset.path, "Video texture decoding failed: " + error.localizedDescription)
                        return nil
                    }
                }
                if let animation = parser.extractAnimation() {
                    animationCache[cacheKey] = animation
                    textureCache[cacheKey] = animation.images[0]
                    return animation.images[0]
                }
                if let image = parser.extractImage() { textureCache[cacheKey] = image; return image }
            } else if let image = NSImage(data: asset.data) {
                textureCache[cacheKey] = image
                return image
            }
            assetResolver?.report(.invalid, asset.path, "Texture format is invalid or unsupported")
        } else if name != "util/white" {
            _ = assetResolver?.asset(candidates: candidates, required: true)
        }
        if name == "util/white" {
            let image = NSImage(size: CGSize(width: 1, height: 1), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill(); return true
            }
            textureCache[cacheKey] = image
            return image
        }
        if name == "particle/beam/beam_1" {
            warn("Approximate built-in texture: " + name)
            let image = generateRadialGradient(size: CGSize(width: 32, height: 32), color: .white)
            textureCache[cacheKey] = image
            return image
        }
        return nil
    }

    /// Generate simple procedural textures for built-in particle names
    private func generateProceduralTexture(named name: String) -> NSImage? {
        let size: CGFloat = 32

        switch name {
        case "particle/drop":
            warn("Approximate built-in texture: " + name)
            // Elongated raindrop: bright center, soft edges
            return generateRadialGradient(size: CGSize(width: 4, height: 16), color: .white)

        case _ where name.contains("halo"):
            warn("Approximate built-in texture: " + name)
            // Soft circular glow
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)

        default:
            warn("Unknown built-in particle texture: " + name)
            return nil
        }
    }

    private func generateRadialGradient(size: CGSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Convert to RGB color space to guarantee 4 components (r, g, b, a)
        let rgbColor = color.usingColorSpace(.deviceRGB) ?? color
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent
        let a = rgbColor.alphaComponent
        let colors = [
            CGColor(colorSpace: colorSpace, components: [r, g, b, a])!,
            CGColor(colorSpace: colorSpace, components: [r, g, b, 0])!
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])

        image.unlockFocus()
        return image
    }

    // MARK: - System Events

    @objc func systemWillSleep(_ notification: Notification) {
        print("[SceneVM] System is going to sleep")
        sleepReasons.insert(notification.name == NSWorkspace.willSleepNotification ? "system" : "display")
        sleeping = !sleepReasons.isEmpty
        applyPlayback()
    }

    @objc func systemDidWake(_ notification: Notification) {
        print("[SceneVM] System woke up")
        sleepReasons.remove(notification.name == NSWorkspace.didWakeNotification ? "system" : "display")
        sleeping = !sleepReasons.isEmpty
        videoRecoveryAttempts = 0
        applyPlayback()
    }
}

extension SceneWallpaperViewModel {
    /// Explicit ports of the effects used by fixture 3799672625, composed in file order.
    /// Unknown shaders are diagnosed; this is not a general GLSL translator.
    private func applyEffects(_ object: WESceneObject, to node: SKSpriteNode, wallpaperDir: URL) {
        let effects = object.effects ?? []
        guard !effects.isEmpty || object.brightness != nil else { return }
        let tint = (object.color ?? "1 1 1").parseColor()
        var source = "vec4 result = texture2D(u_texture, uv); if (result.a > 0.0) result.rgb /= result.a; result.rgb *= u_layerTint * \(object.brightness ?? 1);\n"
        var uniforms: [SKUniform] = [SKUniform(name:"u_layerTint",vectorFloat3:SIMD3(Float(tint.r),Float(tint.g),Float(tint.b))),
                                      SKUniform(name:"u_layerScale",vectorFloat2:SIMD2(1,1))]
        var bindings: [[String:Any]] = []
        var names = Set<String>()
        var step = 0
        for (effectIndex,effect) in effects.enumerated() {
            let key = URL(fileURLWithPath: effect.file).deletingLastPathComponent().lastPathComponent
            let pass = effect.passes?.first
            let values = pass?.constantshadervalues ?? [:]
            func uniformName(_ key:String) -> String { "p\(effectIndex)_" + key.utf8.map { String(format:"%02x",$0) }.joined() }
            func n(_ key:String,_ fallback:Double) -> String {
                let name=uniformName(key)
                if names.insert(name).inserted {
                    let value=values[key]?.number ?? fallback
                    uniforms.append(SKUniform(name:name,float:Float(value.isFinite ? value : fallback)))
                    bindings.append(["name":name,"effect":effectIndex,"key":key,"count":1])
                }
                return name
            }
            func v(_ key:String,_ fallback:String,_ count:Int) -> String {
                let name=uniformName(key)
                if names.insert(name).inserted {
                    let numbers=(values[key]?.string ?? fallback).replacingOccurrences(of: ",", with: " ").split(separator:" ").compactMap { Float($0) }
                    let defaults=fallback.split(separator:" ").compactMap { Float($0) }
                    let safe=(0..<count).map { i in i < numbers.count && numbers[i].isFinite ? numbers[i] : defaults[i] }
                    uniforms.append(count == 2 ? SKUniform(name:name,vectorFloat2:SIMD2(safe[0],safe[1])) : SKUniform(name:name,vectorFloat3:SIMD3(safe[0],safe[1],safe[2])))
                    bindings.append(["name":name,"effect":effectIndex,"key":key,"count":count])
                }
                return name
            }
            let enabledName="effectEnabled\(effectIndex)"
            uniforms.append(SKUniform(name:enabledName,float:effect.visible?.bool == false ? 0 : 1))
            bindings.append(["name":enabledName,"effect":effectIndex,"key":"visible","count":0])
            let previous = "effect\(step)"
            var body = ""
            switch key {
            case "opacity", "user_texture_alpha_overwrite_workaround":
                var mask = "1.0"
                if let textures = pass?.textures, textures.count > 1, let name = textures[1] {
                    if let image = loadTexture(named: name, materialDir: "materials/", wallpaperDir: wallpaperDir) {
                        let uniformName = "mask\(step)"
                        uniforms.append(SKUniform(name: uniformName, texture: SKTexture(image: image)))
                        mask = "texture2D(\(uniformName), uv).r"
                    } else { warn("Missing opacity mask: " + name) }
                }
                body = "vec4 c = \(previous)(uv); c.a *= \(n("alpha", 1)) * \(mask); return c;"
            case "tint":
                let mode = pass?.combos?["BLENDMODE"] ?? 30
                guard [22, 30].contains(mode) else { warn("Unsupported tint blend mode: " + effect.file); continue }
                var mask = "1.0"
                if let textures = pass?.textures, textures.count > 1, let name = textures[1],
                   let image = loadTexture(named: name, materialDir: "materials/", wallpaperDir: wallpaperDir) {
                    let uniformName = "tintMask\(step)"
                    uniforms.append(SKUniform(name: uniformName, texture: SKTexture(image: image)))
                    mask = "texture2D(\(uniformName), uv).r"
                }
                let color = v("color", "1 0 0", 3)
                let tinted = mode == 30 ? "vec3(max(c.r, max(c.g, c.b))) * \(color)"
                    : "mix(min(\(color) * \(color) / max(vec3(0.000001), vec3(1.0) - c.rgb), vec3(1.0)), vec3(1.0), step(vec3(1.0), c.rgb))"
                body = "vec4 c = result; c.rgb = mix(c.rgb, \(tinted), \(n("alpha", 1)) * \(mask)); return c;"
            case "colorkey":
                body = """
                vec4 c = result;
                float d = dot(abs(\(v("color", "1 1 1", 3)) - c.rgb), vec3(1.0));
                float blend = smoothstep(0.001, 0.002 + \(n("fuzziness", 0)), d - \(n("tolerance", 0.1)));
                \((pass?.combos?["INVERT"] ?? 0) == 1 ? "blend = 1.0 - blend;" : "")
                c.a *= mix(\(n("alpha", 0)), 1.0, blend);
                \((pass?.combos?["FLATTEN"] ?? 0) == 1 ? "c.rgb *= c.a;" : "")
                return c;
                """
            case "shake":
                guard (pass?.combos?["NOISE"] ?? 0) == 0,
                      (pass?.combos?["AUDIOPROCESSING"] ?? 0) == 0,
                      (pass?.combos?["TIMEOFFSET"] ?? 0) == 0,
                      (pass?.combos?["MASK"] ?? 0) == 0 else {
                    warn("Unsupported shake mode: " + effect.file); continue
                }
                var flow = "vec2(0.0)"
                if let textures = pass?.textures, textures.count > 1, let path = textures[1],
                   let image = loadTexture(named: path, materialDir: "materials/", wallpaperDir: wallpaperDir) {
                    let name = "flow\(effectIndex)"
                    uniforms.append(SKUniform(name: name, texture: SKTexture(image: image)))
                    flow = "(texture2D(\(name), uv).rg - vec2(0.498)) * 2.0"
                }
                if !uniforms.contains(where: { $0.name == "u_scrollTime" }) { uniforms.append(SKUniform(name: "u_scrollTime", float: 0)) }
                let direction = pass?.combos?["DIRECTION"] ?? 0
                body = """
                float t = \(n("speed", 1)) * u_scrollTime;
                float phase = sin(t) * 0.498 + 0.5;
                vec2 friction = max(vec2(0.001), \(v("friction", "1 1", 2)));
                phase = mix(1.0 - pow(1.0-phase, friction.x), pow(phase, friction.y), step(0.0, cos(t)));
                vec2 bounds = \(v("bounds", "0 1", 2));
                phase = clamp((phase - bounds.x) / max(0.00001, bounds.y - bounds.x), 0.0, 1.0);
                phase = \(direction == 0 ? "phase * 2.0 - 1.0" : direction == 2 ? "phase - 1.0" : "phase");
                vec2 displaced = clamp(uv + phase * pow(\(n("strength", 0.1)), 2.0) * \(flow), 0.0, 1.0);
                vec4 moved; { vec2 uv = displaced; \(source) moved = result; } result = moved;
                """
            case "_________________________________":
                guard effect.file.contains("/3444196917/"), [0,1].contains(pass?.combos?["SHAPE"] ?? 0),
                      (pass?.combos?["BAR_STYLE"] ?? 1) == 1 else {
                    warn("Unsupported rounded audio bars mode: " + effect.file); continue
                }
                if !uniforms.contains(where: { $0.name == "u_audioSpectrum" }) {
                    uniforms.append(SKUniform(name:"u_audioSpectrum",texture:SceneSpectrumTexture.texture(Array(repeating:0,count:64))))
                }
                let aspect = Double(node.size.width / max(1,node.size.height))
                let top = (pass?.combos?["SHAPE"] ?? 0) == 1
                body = """
                float count = clamp(\(n("音频条数量",32)), 1.0, 200.0);
                float freq = floor(min(uv.x,0.999999)*count)/count*32.0;
                float bin = floor(freq);
                float a = texture2D(u_audioSpectrum,vec2((bin+0.5)/32.0,0.5)).r;
                float b = texture2D(u_audioSpectrum,vec2((mod(bin+1.0,32.0)+0.5)/32.0,0.5)).r;
                float volume = mix(a,b,smoothstep(0.0,1.0,fract(freq)));
                volume = log(9.0*volume+1.0)/log(10.0) * \(n("音量因子",1));
                float width = (1.0-clamp(\(n("音频条间距",0.1)),0.0,1.0))/count;
                vec2 bounds = \(v("音频条上下限范围","0 0.2",2));
                float minHeight = \(n("最小高度（将乘以音频条宽度）",0)) * width * \(aspect);
                float height = max(0.0,mix(max(bounds.x,minHeight),bounds.y,volume));
                vec2 halfSize = vec2(width*\(aspect),height)*0.5;
                vec2 p = vec2((fract(uv.x*count)-0.5)/count*\(aspect), \(top ? "1.0-uv.y" : "uv.y")-height*0.5);
                float radius = clamp(\(n("圆角半径",1)),0.0,1.0)*min(halfSize.x,halfSize.y);
                float distance = length(max(abs(p)-halfSize+radius,0.0))-radius;
                vec2 aa = \(v("抗锯齿模糊度","0.05 0",2))*\(15.0 / max(1,min(node.size.width,node.size.height)));
                float mask = (1.0-smoothstep(-max(0.000001,aa.x),max(0.000001,aa.y),distance))*step(0.000001,height);
                return vec4(\(v("音频条颜色","1 1 1",3)), mask*\(n("音频条不透明度",1)));
                """
            case "highly_customizable_audio_visualizer":
                guard (pass?.combos?["U_FORM"] ?? 0) == 3 else {
                    warn("Unsupported custom audio visualizer form: " + effect.file); continue
                }
                if !uniforms.contains(where: { $0.name == "u_audioSpectrum" }) {
                    uniforms.append(SKUniform(name:"u_audioSpectrum",texture:SceneSpectrumTexture.texture(Array(repeating:0,count:64))))
                }
                body = """
                float bandPos = abs(uv.x-0.5)*2.0;
                float low = min(\(n("频段下限",0)),\(n("频段上限",31)));
                float high = max(\(n("频段下限",0)),\(n("频段上限",31)));
                float band = mix(low,high,bandPos), idx = floor(band), t = fract(band);
                float sensitivity = max(0.01,\(n("灵敏度",0.5)));
                float p0 = pow(texture2D(u_audioSpectrum,vec2((clamp(idx-1.0,0.0,63.0)+0.5)/64.0,0.5)).r,sensitivity);
                float p1 = pow(texture2D(u_audioSpectrum,vec2((clamp(idx,0.0,63.0)+0.5)/64.0,0.5)).r,sensitivity);
                float p2 = pow(texture2D(u_audioSpectrum,vec2((clamp(idx+1.0,0.0,63.0)+0.5)/64.0,0.5)).r,sensitivity);
                float p3 = pow(texture2D(u_audioSpectrum,vec2((clamp(idx+2.0,0.0,63.0)+0.5)/64.0,0.5)).r,sensitivity);
                float value = max(0.0,0.5*(2.0*p1+(-p0+p2)*t+(2.0*p0-5.0*p1+4.0*p2-p3)*t*t+(-p0+3.0*p1-3.0*p2+p3)*t*t*t));
                float wave = sin(bandPos*3.14159265359*\(n("交替频率",3)));
                if(wave<0.0) wave *= \(n("波谷深度",1.5));
                float curve = value*pow(max(0.0,1.0-bandPos),max(0.01,\(n("渐隐强度",2))))*wave*\(n("振幅",0.5));
                float thickness = max(0.0001,\(n("线条粗细",0.006)));
                float mask = 1.0-smoothstep(thickness,thickness+max(0.0015,thickness*0.5),abs(uv.y-0.5-curve));
                vec3 color = bandPos<0.5 ? mix(\(v("1 主色","1 1 1",3)),\(v("2 中间色","0 0 1",3)),bandPos*2.0) : mix(\(v("2 中间色","0 0 1",3)),\(v("3 副色","0 1 1",3)),(bandPos-0.5)*2.0);
                return vec4(color,mask);
                """
            case "fisheye":
                body = """
                vec2 originalUV = vec2(uv.x,1.0-uv.y);
                vec2 center = \(v("center","0.5 0.5",2));
                float size = max(0.0001,\(n("size",1)));
                vec2 xy = (originalUV-center)*2.0/size;
                float d = length(xy), alpha = 1.0;
                vec2 warped = originalUV;
                if(d < 1.00015230484) {
                    float radius = asin(clamp(d*0.99984769516,0.0,1.0))/3.14159265359;
                    warped = center + (d>0.000001 ? xy/d : vec2(0.0))*radius*size;
                } else { alpha = \((pass?.combos?["BACKGROUND"] ?? 1) == 0 ? "0.0" : "1.0"); }
                warped = mix(originalUV,warped,\(n("distortion",1)));
                vec4 distorted; { vec2 uv = vec2(warped.x,1.0-warped.y); \(source) distorted = result; }
                result = distorted; result.a *= alpha;
                """
            case "Simple_Audio_Bars":
                // Port the authored bottom-bars/replace-alpha variant. Other combinations
                // remain diagnosed instead of silently rendering a different effect.
                let defaults = ["SHAPE": 0, "TRANSPARENCY": 1, "BLENDMODE": 0, "A_SMOOTH_CURVE": 0, "ANTIALIAS": 0]
                guard defaults.allSatisfy({ (pass?.combos?[$0.key] ?? $0.value) == $0.value }) else {
                    warn("Unsupported audio bars mode: " + effect.file); continue
                }
                if !uniforms.contains(where: { $0.name == "u_audioSpectrum" }) {
                    uniforms.append(SKUniform(name:"u_audioSpectrum", texture:SceneSpectrumTexture.texture(Array(repeating:0,count:64))))
                }
                let resolution = [16,32,64].contains(pass?.combos?["RESOLUTION"] ?? 32) ? (pass?.combos?["RESOLUTION"] ?? 32) : 32
                body = """
                float count = clamp(\(n("Bar Count", 32)), 1.0, 256.0);
                float frequency = floor(min(uv.x, 0.999999) * count) / count * \(resolution).0;
                float bin = mod(floor(frequency), \(resolution).0);
                float a = texture2D(u_audioSpectrum, vec2((bin + 0.5) / \(resolution).0, 0.5)).r;
                float b = texture2D(u_audioSpectrum, vec2((mod(bin+1.0, \(resolution).0)+0.5) / \(resolution).0, 0.5)).r;
                float volume = mix(a, b, smoothstep(0.0, 1.0, fract(frequency)));
                vec2 bounds = \(v("Lower/Upper Bar Bounds", "0 1", 2));
                float height = mix(bounds.x, bounds.y, volume);
                float bar = step(uv.y, height) * step(abs(fract(uv.x*count)*2.0-1.0), 1.0-\(n("Bar Spacing", 0.1)));
                \((pass?.combos?["CLIP_LOW"] ?? 0) == 1 ? "bar *= 1.0 - step(uv.y, bounds.x);" : "")
                \((pass?.combos?["CLIP_HIGH"] ?? 0) == 1 ? "bar *= step(uv.y, bounds.y);" : "")
                return vec4(\(v("Bar Color", "1 1 1", 3)), bar * \(n("ui_editor_properties_opacity", 1)));
                """
            case "scroll":
                let sx = n("speedx", 0), sy = n("speedy", 0), repeats = v("repeat", "1 1", 2)
                if !uniforms.contains(where: { $0.name == "u_scrollTime" }) { uniforms.append(SKUniform(name: "u_scrollTime", float: 0)) }
                body = "vec2 scrollSpeed = vec2(sign(\(sx)) * \(sx) * \(sx), sign(\(sy)) * \(sy) * \(sy)); vec2 scrollUV = fract(uv * \(repeats) + scrollSpeed * u_scrollTime); vec4 scrolled; { vec2 uv = scrollUV; " + source + " scrolled = result; } result = scrolled;"
            case "spin":
                let aspect = Double(node.size.width / max(1, node.size.height))
                body = """
                vec2 center = \(v("center", "0.5 0.5", 2));
                vec2 p = uv - center; p.x *= \(aspect);
                float axis = \(n("angle", 0)); float ratio = max(0.00001, \(n("ratio", 1)));
                mat2 a = mat2(cos(axis), sin(axis), -sin(axis), cos(axis));
                p = a * p; p.x *= ratio;
                vec2 soft = p;
                float t = \(n("speed", 1)) * u_time + \(n("phase", 0)) * 6.28318530718;
                p = mat2(cos(t), sin(t), -sin(t), cos(t)) * p;
                p.x /= ratio; p = transpose(a) * p; p.x /= \(aspect);
                float feather = max(0.00001, \(n("feather", 0.002)));
                float mask = 1.0 - smoothstep(\(n("size", 0.1)) - feather, \(n("size", 0.1)) + feather, length(soft));
                return mix(\(previous)(uv), \(previous)(fract(p + center)), mask);
                """
            case "video":
                uniforms.append(SKUniform(name:"u_audioSpectrum",texture:SceneSpectrumTexture.texture(Array(repeating:0,count:64))))
                body = """
                vec2 p = uv - 0.5; float coverage = 0.0;
                for (int i = 0; i < 64; i++) {
                    float t = 6.28318530718 * float(i) / 64.0;
                    vec2 direction = vec2(sin(t), cos(t));
                    float height = texture2D(u_audioSpectrum, vec2((float(i)+0.5)/64.0,0.5)).r * \(n("Sound Strength",0.1));
                    float along = dot(p,direction)-\(n("R",0.3));
                    float across = dot(p,vec2(direction.y,-direction.x));
                    float distance = length(vec2(across,max(abs(along)-height,0.0)))-0.004;
                    coverage = max(coverage,1.0-smoothstep(-0.001,0.001,distance));
                }
                return vec4(\(v("color", "1 1 1", 3)) * coverage, 1.0);
                """
            case "custom_user_texture":
                if let textures = pass?.textures, textures.count > 1, let name = textures[1],
                   let image = loadTexture(named: name, materialDir: "materials/", wallpaperDir: wallpaperDir) {
                    let uniformName = "custom\(effectIndex)"
                    uniforms.append(SKUniform(name: uniformName, texture: SKTexture(image: image)))
                    body = "vec4 c = texture2D(\(uniformName), uv); if (c.a > 0.0) c.rgb /= c.a; c.rgb *= \(n("multiply", 1)); return c;"
                } else { warn("Missing custom texture: " + effect.file); continue }
            case "frame_builder_by_gariam":
                guard (pass?.combos?["TYPE"] ?? 0) == 0 else {
                    warn("Unsupported frame shape: " + effect.file); continue
                }
                body = """
                vec4 pix = \(previous)(uv);
                vec2 res = \(v("Reference resolution", "512 512", 2));
                vec2 scale = abs(u_layerScale);
                float softness = max(0.00001, \(n("ui_settings_gfx_antialiasing", 1)));
                float thickness = \(n("Thickness", 0.1)) * res.x * 0.05;
                float notchSize = max(0.000001, \(n("Notch size", 0.5)) * res.x * 0.2) * 1.41421356237;
                vec2 p = (vec2(uv.x, 1.0-uv.y) + \(v("ui_editor_properties_position", "0 0", 2)) - 0.5) * res * scale;
                float angle = \(n("ui_editor_properties_rotation", 0));
                p = mat2(cos(angle), sin(angle), -sin(angle), cos(angle)) * p;
                vec2 size = \(v("ui_editor_properties_size", "1 1", 2)) * res * 0.5 * scale - thickness - 2.0 * softness;
                float enabled = p.x < 0.0 ? (p.y < 0.0 ? \(n("Top left", 1)) : \(n("Bottom left", 1))) : (p.y < 0.0 ? \(n("Top right", 1)) : \(n("Bottom right", 1)));
                notchSize *= enabled;
                vec2 sdf = abs(p) - size - \(n("Edge extrude", 0)) * res.x * 0.1;
                float notch = length(abs(p) - size + notchSize - thickness) - notchSize + thickness;
                vec2 quadrant = p - (size - (notchSize - thickness)) * sign(p);
                if (!(sign(p.x) == sign(quadrant.x) && sign(p.y) == sign(quadrant.y))) notch = -100000.0;
                float edge = max(notch, max(sdf.x, sdf.y));
                float outside = 1.0;
                if (edge >= thickness) { edge = thickness - edge + softness; outside = 0.0; }
                if (edge > softness) outside = 0.0;
                edge = smoothstep(-softness, softness, edge);
                vec2 ia = \(v("insideAlpha", "0 0.3", 2));
                vec2 oa = \(v("outAlpha", "0 0", 2));
                vec2 fa = \(v("frameAlpha", "0 1", 2));
                vec4 frame = vec4(mix(pix.rgb, \(v("frameColor", "1 1 1", 3)), fa.x), fa.y);
                vec4 inside = vec4(mix(pix.rgb, \(v("inColor", "0.3 0.3 0.3", 3)), ia.x), ia.y);
                vec4 outer = vec4(mix(pix.rgb, \(v("outColor", "0 0 0", 3)), oa.x), oa.y);
                return mix(pix, mix(outside > 0.5 ? inside : outer, frame, edge), \(n("ui_editor_properties_opacity", 1)));
                """
            default:
                _ = assetResolver?.data(effect.file, required: true)
                warn("Unsupported effect: " + effect.file); continue
            }
            if key == "spin" {
                // Inline the preceding pipeline at the rotated UV as well as the
                // original UV. SpriteKit uniforms are only available inside main.
                body = body.replacingOccurrences(
                    of: "return mix(\(previous)(uv), \(previous)(fract(p + center)), mask);",
                    with: "vec4 original = result; vec4 spun; { vec2 uv = fract(p + center); " + source + " spun = result; } result = mix(original, spun, mask);")
            } else if key != "scroll" && key != "shake" && key != "fisheye" {
                body = body.replacingOccurrences(of: "\(previous)(uv)", with: "result")
                    .replacingOccurrences(of: "return ", with: "result = ")
            }
            step += 1
            source += "{ if (\(enabledName) > 0.5) { \(body) } }\n"
        }
        // The exported spectrum opacity is very faint over bright wallpaper.
        // Boost this generated overlay only; preserve zero opacity and leave the
        // separate cover texture and ordinary opacity effects unchanged.
        if effects.contains(where: { URL(fileURLWithPath: $0.file).deletingLastPathComponent().lastPathComponent == "video" }) {
            source += "result.a = clamp(result.a * 3.0, 0.0, 1.0);\n"
        }
        // SpriteKit consumes premultiplied output. Preserve the layer's tint and alpha.
        source = "void main() { vec2 uv = v_tex_coord; " + source
            + " vec4 c = result; c.rgb *= c.a; gl_FragColor = c * v_color_mix.a; }"
        node.shader = SKShader(source: source, uniforms: uniforms)
        node.userData = node.userData ?? NSMutableDictionary()
        node.userData?["effectBindings"] = bindings
    }
    private static func updateEffectUniforms(_ node:SKSpriteNode,effects:[[String:Any]]) {
        node.shader?.uniformNamed("u_layerScale")?.vectorFloat2Value = SIMD2(Float(node.parent?.xScale ?? 1),Float(node.parent?.yScale ?? 1))
        for binding in node.userData?["effectBindings"] as? [[String:Any]] ?? [] {
            guard let name=binding["name"] as? String,let index=binding["effect"] as? Int,index < effects.count,
                  let key=binding["key"] as? String,let count=binding["count"] as? Int,let uniform=node.shader?.uniformNamed(name) else { continue }
            if count == 0 { uniform.floatValue = effects[index]["visible"] as? Bool == false ? 0 : 1;continue }
            let passes=effects[index]["passes"] as? [[String:Any]] ?? []
            let raw=(passes.first?["constantshadervalues"] as? [String:Any])?[key]
            if count == 1,let number=raw as? NSNumber,number.floatValue.isFinite { uniform.floatValue=number.floatValue;continue }
            var numbers:[Float] = []
            if let value=raw as? String { numbers=value.split(separator:" ").compactMap { Float($0) } }
            if let value=raw as? [String:NSNumber] { numbers=["x","y","z"].compactMap { value[$0]?.floatValue } }
            if numbers.count >= count && numbers.allSatisfy({$0.isFinite}) {
                if count == 2 { uniform.vectorFloat2Value=SIMD2(numbers[0],numbers[1]) }
                if count == 3 { uniform.vectorFloat3Value=SIMD3(numbers[0],numbers[1],numbers[2]) }
            }
        }
    }

}
