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
    private(set) var renderingWarnings: [String] = []
    private var pkgParser: PKGParser?
    private var videoPlayer: AVQueuePlayer?
    private var videoLooper: AVPlayerLooper?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var readinessTimer: Timer?
    private var audioPlayers: [(AVAudioPlayer, Float)] = []
    private var temporaryDirectory: URL?
    private var cancellables = Set<AnyCancellable>()
    private var volumeSubscription: AnyCancellable?
    private var audioError: String?
    private var sleeping = false
    private var playRate: Float = 0
    private var playVolume: Float = 0
    private weak var fallbackNode: SKNode?
    private weak var errorNode: SKLabelNode?

    func stop() {
        WallpaperPlaybackSessions.shared.unregister(self, screenId: screenId)
        volumeSubscription = nil
        readinessTimer?.invalidate()
        readinessTimer = nil
        videoPlayer?.pause()
        videoLooper?.disableLooping()
        videoPlayer?.removeAllItems()
        videoLooper = nil
        videoPlayer = nil
        videoOutput = nil
        audioPlayers.forEach { $0.0.stop() }
        audioPlayers.removeAll()
        skScene?.removeAllChildren()
        fontCache.removeAll()
        textureCache.removeAll()
        renderingWarnings.removeAll()
        pkgParser = nil
        if let directory = temporaryDirectory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Self.log("Temporary media cleanup failed: \(error)") }
        }
        temporaryDirectory = nil
        audioError = nil
    }

    private func applyPlayback() {
        let rate: Float = sleeping ? 0 : playRate
        videoPlayer?.rate = rate
        videoPlayer?.volume = audioEnabled ? playVolume : 0
        for (player, volume) in audioPlayers {
            player.volume = audioEnabled ? volume * playVolume : 0
            if rate == 0 { player.pause() }
            else { player.rate = rate; if !player.isPlaying { player.play() } }
        }
        skScene?.isPaused = rate == 0
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
        Self.log(message)
        errorNode?.text = message
        errorNode?.isHidden = false
        fallbackNode?.isHidden = false
    }


    init(wallpaper: WEWallpaper, screenId: String = UUID().uuidString) {
        self.screenId = screenId
        self.currentWallpaper = wallpaper
        Self.log("init: wallpaper=\(wallpaper.project.title ?? "?") dir=\(wallpaper.wallpaperDirectory.path)")
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        let shared = AppDelegate.shared.wallpaperViewModel
        playRate = shared.playRate
        playVolume = shared.playVolume
        shared.$playRate.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.playRate = value
            self?.applyPlayback()
        }.store(in: &cancellables)
        loadScene(from: wallpaper)
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Scene Loading

    func loadScene(from wallpaper: WEWallpaper) {
        stop()
        WallpaperPlaybackSessions.shared.register(self, screenId: screenId)
        volumeSubscription = AppDelegate.shared.wallpaperViewModel.volumePublisher(for: wallpaper)
            .sink { [weak self] volume in
                self?.playVolume = volume
                self?.applyPlayback()
            }
        let dir = wallpaper.wallpaperDirectory
        let sceneFile = wallpaper.project.file  // e.g. "scene.json" or "gifscene.json"

        // Derive PKG name from scene file: "scene.json" → "scene.pkg", "gifscene.json" → "gifscene.pkg"
        let pkgName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let pkgURL = dir.appending(path: pkgName)
        let looseSceneURL = dir.appending(path: sceneFile)

        var scene: WEScene?
        var loadError = "Scene file not found: " + sceneFile

        if FileManager.default.fileExists(atPath: pkgURL.path(percentEncoded: false)) {
            do {
                let parser = try PKGParser(url: pkgURL)
                self.pkgParser = parser
                if let data = parser.extractFile(named: sceneFile) {
                    scene = try WEScene.decode(data: data, projectData: try? Data(contentsOf: dir.appendingPathComponent("project.json")))
                }
            } catch {
                loadError = error.localizedDescription
                Self.log("Failed to parse PKG: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: looseSceneURL.path(percentEncoded: false)) {
            // Loose files (no .pkg)
            self.pkgParser = nil
            do {
                let data = try Data(contentsOf: looseSceneURL)
                scene = try WEScene.decode(data: data, projectData: try? Data(contentsOf: dir.appendingPathComponent("project.json")))
            } catch {
                loadError = error.localizedDescription
                Self.log("Failed to parse loose \(sceneFile): \(error)")
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

        Self.log("Scene loaded: \(scene.objects.count) objects from \(sceneFile)")
        let skScene = buildSKScene(from: scene, wallpaperDir: dir)
        Self.log("SKScene built: \(skScene.children.count) children")
        self.skScene = skScene
        loadAudio(from: scene, wallpaperDir: dir)
        applyPlayback()
    }

    // MARK: - SpriteKit Scene Building

    private func buildSKScene(from scene: WEScene, wallpaperDir: URL) -> SKScene {
        let projection = scene.general.orthogonalprojection ?? WEOrthogonalProjection(width: 1920, height: 1080)
        let skScene = SKScene(size: CGSize(width: projection.width, height: projection.height))
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
        let backgroundIndex = scene.objects.indices.filter {
            scene.objects[$0].image != nil && visible(containers[$0])
        }.max {
            let a = (scene.objects[$0].size ?? "0 0").parseVector2()
            let b = (scene.objects[$1].size ?? "0 0").parseVector2()
            return a.0 * a.1 < b.0 * b.1
        }
        for (index, object) in scene.objects.enumerated() {
            let holder = containers[index]
            if index == backgroundIndex && buildVideoNode(object, in: skScene, wallpaperDir: wallpaperDir) {
                if let video = skScene.children.last as? SKVideoNode {
                    video.removeFromParent(); video.position = .zero
                    video.xScale = 1; video.yScale = 1; video.zRotation = 0
                    video.zPosition = CGFloat(index + 1)
                    holder.addChild(video)
                }
            } else if let image = buildImageNode(object, wallpaperDir: wallpaperDir) {
                image.position = .zero
                image.zPosition = CGFloat(index + 1)
                holder.addChild(image)
                if index == backgroundIndex { fallbackNode?.isHidden = true }
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
        if let data = pkgParser?.extractFile(named: path) { return Data(data) }
        return try? Data(contentsOf: wallpaperDir.appendingPathComponent(path))
    }

    private func buildVideoNode(_ object: WESceneObject, in scene: SKScene, wallpaperDir: URL) -> Bool {
        guard let modelPath = object.image,
              let model: WEModel = loadJSON(path: modelPath, wallpaperDir: wallpaperDir),
              let materialPath = model.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir),
              let name = material.passes?.first?.textures?.first ?? nil else { return false }
        let directory = (materialPath as NSString).deletingLastPathComponent
        for path in [directory + "/" + name + ".tex", "materials/" + name + ".tex", name + ".tex"] {
            guard let data = assetData(path, wallpaperDir: wallpaperDir),
                  let video = TEXParser(data: data).extractVideoData() else { continue }
            do {
                let url = try mediaURL(data: video, extension: "mp4")
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
                scene.addChild(node)
                var elapsed: Double = 0
                var hasFrame = false
                readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak node] timer in
                    guard let self = self, let player = self.videoPlayer else { timer.invalidate(); return }
                    if player.status == .failed || player.currentItem?.status == .failed || self.videoLooper?.status == .failed {
                        self.reportFailure("Background playback failed: " + (player.currentItem?.error?.localizedDescription ?? player.error?.localizedDescription ?? self.videoLooper?.error?.localizedDescription ?? "Invalid video"))
                        node?.isHidden = true
                        player.pause()
                        timer.invalidate()
                        return
                    }
                    guard !hasFrame else { return }
                    if let current = player.currentItem {
                        if self.videoOutput == nil || !current.outputs.contains(where: { $0 === self.videoOutput }) {
                            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                            current.add(output)
                            self.videoOutput = output
                        }
                        if let output = self.videoOutput,
                           output.copyPixelBuffer(forItemTime: current.currentTime(), itemTimeForDisplay: nil) != nil {
                            node?.isHidden = false
                            self.fallbackNode?.isHidden = true
                            self.errorNode?.isHidden = self.audioError == nil
                            hasFrame = true
                            current.remove(output)
                            self.videoOutput = nil
                            elapsed = 0
                        } else if !self.sleeping && self.playRate != 0 {
                            elapsed += 0.1
                            if elapsed > 15 { self.reportFailure("Background video has not produced a frame") }
                        }
                    }
                }
            } catch { reportFailure("Video extraction failed: " + error.localizedDescription) }
            return true
        }
        return false
    }

    private func loadAudio(from scene: WEScene, wallpaperDir: URL) {
        for object in scene.objects where object.visible != false && object.startsilent != true {
            guard let path = object.sound?.first else { continue }
            do {
                guard let data = assetData(path, wallpaperDir: wallpaperDir) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let url = try mediaURL(data: data, extension: (path as NSString).pathExtension)
                let player = try AVAudioPlayer(contentsOf: url)
                player.numberOfLoops = object.playbackmode == "loop" ? -1 : 0
                player.enableRate = true
                player.prepareToPlay()
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
        let textureName = (obj.instance?.textures?.first ?? nil)
            ?? (material?.passes?.first?.textures?.first ?? nil)
            ?? (materialPath.hasPrefix("materials/util/solidlayer") ? "util/white" : nil)
        guard let textureName = textureName,
              let image = loadTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir) else {
            warn("Missing image material/texture: " + imagePath)
            return nil
        }
        let texture = SKTexture(image: image)
        let node = SKSpriteNode(texture: texture)

        // Size from object, or use pixel dimensions (not point size, which is halved on Retina)
        if let sizeStr = obj.size {
            let (w, h) = sizeStr.parseVector2()
            node.size = CGSize(width: w, height: h)
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
        return node
    }

    private func warn(_ message: String) {
        if !renderingWarnings.contains(message) { renderingWarnings.append(message); Self.log(message) }
    }

    private func anchorPoint(_ alignment: String?) -> CGPoint {
        let alignment = alignment ?? "center"
        return CGPoint(x: alignment.contains("left") ? 0 : alignment.contains("right") ? 1 : 0.5,
                       y: alignment.contains("bottom") ? 0 : alignment.contains("top") ? 1 : 0.5)
    }

    private func buildTextNode(_ object: WESceneObject, wallpaperDir: URL) -> SKLabelNode {
        var font = NSFont.systemFont(ofSize: object.pointsize ?? 24)
        if let path = object.font {
            if let cached = fontCache[path] { font = cached }
            else if let bytes = assetData(path, wallpaperDir: wallpaperDir),
                    let provider = CGDataProvider(data: bytes as CFData), let cgFont = CGFont(provider) {
                // An in-memory font avoids global registration conflicts across displays.
                font = CTFontCreateWithGraphicsFont(cgFont, 24, nil, nil) as NSFont
                fontCache[path] = font
            } else { warn("Unable to load font: " + path) }
        }
        font = NSFont(descriptor: font.fontDescriptor, size: object.pointsize ?? 24) ?? font
        let c = (object.color ?? "1 1 1").parseColor()
        let node = SKLabelNode()
        node.attributedText = NSAttributedString(string: object.text ?? "", attributes: [
            .font: font, .foregroundColor: NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        ])
        node.alpha = object.alpha ?? 1
        node.horizontalAlignmentMode = object.horizontalalign == "left" ? .left : object.horizontalalign == "right" ? .right : .center
        node.verticalAlignmentMode = object.verticalalign == "top" ? .top : object.verticalalign == "bottom" ? .bottom : .center
        return node
    }

    // MARK: - Particle Objects

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
        // Try PKG first
        if let parser = pkgParser, let data = parser.extractFile(named: path) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        // Fall back to loose file
        let url = wallpaperDir.appending(path: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func loadTexture(named name: String, materialDir: String, wallpaperDir: URL) -> NSImage? {
        let cacheKey = materialDir + "|" + name
        if let cached = textureCache[cacheKey] { return cached }
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
        // Build candidate .tex paths: relative to material dir, then relative to materials/ root
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        var texPaths = [String]()
        if !materialDirPath.isEmpty {
            texPaths.append("\(materialDirPath)/\(name).tex")
        }
        // Also try materials/{name}.tex for textures with embedded paths (e.g. "workshop/xxx/foo")
        let materialsRoot = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let rootPath = "\(materialsRoot)/\(name).tex"
        if !texPaths.contains(rootPath) {
            texPaths.append(rootPath)
        }
        texPaths.append("\(name).tex")

        for texPath in texPaths {
            // Try .tex from PKG
            if let parser = pkgParser, let texData = parser.extractFile(named: texPath) {
                Self.log("  TEX from PKG '\(texPath)' size=\(texData.count)")
                let texParser = TEXParser(data: Data(texData))  // Copy to reset indices
                if let image = texParser.extractImage() {
                    textureCache[cacheKey] = image
                    return image
                }
                Self.log("  TEXParser.extractImage() returned nil for '\(texPath)'")
            }

            // Try .tex from loose file
            let texURL = wallpaperDir.appending(path: texPath)
            if let texData = try? Data(contentsOf: texURL) {
                let texParser = TEXParser(data: texData)
                if let image = texParser.extractImage() {
                    textureCache[cacheKey] = image
                    return image
                }
            }
        }

        for path in [name, materialDirPath + "/" + name, "materials/" + name] {
            if let data = assetData(path, wallpaperDir: wallpaperDir), let image = NSImage(data: data) {
                textureCache[cacheKey] = image
                return image
            }
        }
        // Try common image formats directly
        for ext in ["png", "jpg", "jpeg", "gif"] {
            let imgPath = materialDirPath.isEmpty ? "\(name).\(ext)" : "\(materialDirPath)/\(name).\(ext)"
            if let parser = pkgParser, let imgData = parser.extractFile(named: imgPath) {
                if let image = NSImage(data: imgData) { return image }
            }
            let imgURL = wallpaperDir.appending(path: imgPath)
            if let image = NSImage(contentsOf: imgURL) { return image }
        }

        Self.log("  No texture found for '\(name)'")
        return nil
    }

    /// Generate simple procedural textures for built-in particle names
    private func generateProceduralTexture(named name: String) -> NSImage? {
        let size: CGFloat = 32

        switch name {
        case "particle/drop":
            // Elongated raindrop: bright center, soft edges
            return generateRadialGradient(size: CGSize(width: 4, height: 16), color: .white)

        case _ where name.contains("halo"):
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
        sleeping = true
        applyPlayback()
    }

    @objc func systemDidWake(_ notification: Notification) {
        print("[SceneVM] System woke up")
        sleeping = false
        applyPlayback()
    }
}

extension SceneWallpaperViewModel {
    /// Explicit ports of the effects used by fixture 3799672625, composed in file order.
    /// Unknown shaders are diagnosed; this is not a general GLSL translator.
    private func applyEffects(_ object: WESceneObject, to node: SKSpriteNode, wallpaperDir: URL) {
        let effects = (object.effects ?? []).filter { $0.visible?.bool != false }
        guard !effects.isEmpty || object.brightness != nil else { return }
        let tint = (object.color ?? "1 1 1").parseColor()
        var source = "vec4 result = texture2D(u_texture, uv); if (result.a > 0.0) result.rgb /= result.a; result.rgb *= vec3(\(tint.r), \(tint.g), \(tint.b)) * \(object.brightness ?? 1);\n"
        var uniforms: [SKUniform] = []
        var step = 0
        for effect in effects {
            let key = URL(fileURLWithPath: effect.file).deletingLastPathComponent().lastPathComponent
            let pass = effect.passes?.first
            let values = pass?.constantshadervalues ?? [:]
            func n(_ key: String, _ fallback: Double) -> String {
                let value = values[key]?.number ?? fallback
                return String(value.isFinite ? value : fallback)
            }
            func v(_ key: String, _ fallback: String, _ count: Int) -> String {
                let numbers = (values[key]?.string ?? fallback).split(separator: " ").compactMap { Double($0) }
                let defaults = fallback.split(separator: " ").compactMap { Double($0) }
                let safe = (0..<count).map { i -> String in
                    let value = i < numbers.count ? numbers[i] : defaults[i]
                    return String(value.isFinite ? value : defaults[i])
                }
                return "vec\(count)(" + safe.joined(separator: ",") + ")"
            }
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
                // Zero-input output of the supplied 64-band shader. Audio data is phase 3.
                warn("Audio spectrum uses zero input until phase three")
                body = """
                vec2 p = uv - 0.5; float coverage = 0.0;
                for (int i = 0; i < 64; i++) {
                    float t = 6.28318530718 * float(i) / 64.0;
                    vec2 center = \(n("R", 0.3)) * vec2(sin(t), cos(t));
                    coverage = max(coverage, 1.0 - step(0.004, length(p - center)));
                }
                return vec4(\(v("color", "1 1 1", 3)) * coverage, 1.0);
                """
            case "custom_user_texture":
                if let textures = pass?.textures, textures.count > 1, let name = textures[1],
                   let image = loadTexture(named: name, materialDir: "materials/", wallpaperDir: wallpaperDir) {
                    let uniformName = "custom\(step)"
                    uniforms.append(SKUniform(name: uniformName, texture: SKTexture(image: image)))
                    body = "vec4 c = texture2D(\(uniformName), uv); if (c.a > 0.0) c.rgb /= c.a; c.rgb *= \(n("multiply", 1)); return c;"
                } else { warn("Missing custom texture: " + effect.file); continue }
            case "frame_builder_by_gariam":
                guard (pass?.combos?["TYPE"] ?? 0) == 0 else {
                    warn("Unsupported frame shape: " + effect.file); continue
                }
                let scale = (object.scale ?? "1 1 1").parseVector3()
                body = """
                vec4 pix = \(previous)(uv);
                vec2 res = \(v("Reference resolution", "512 512", 2));
                vec2 scale = vec2(\(abs(scale.0)), \(abs(scale.1)));
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
                warn("Unsupported effect: " + effect.file); continue
            }
            if key == "spin" {
                // Inline the preceding pipeline at the rotated UV as well as the
                // original UV. SpriteKit uniforms are only available inside main.
                body = body.replacingOccurrences(
                    of: "return mix(\(previous)(uv), \(previous)(fract(p + center)), mask);",
                    with: "vec4 original = result; vec4 spun; { vec2 uv = fract(p + center); " + source + " spun = result; } result = mix(original, spun, mask);")
            } else {
                body = body.replacingOccurrences(of: "\(previous)(uv)", with: "result")
                    .replacingOccurrences(of: "return ", with: "result = ")
            }
            step += 1
            source += "{ \(body) }\n"
        }
        // SpriteKit consumes premultiplied output. Preserve the layer's tint and alpha.
        source = "void main() { vec2 uv = v_tex_coord; " + source
            + " vec4 c = result; c.rgb *= c.a; gl_FragColor = c * v_color_mix.a; }"
        node.shader = SKShader(source: source, uniforms: uniforms)
    }
}
