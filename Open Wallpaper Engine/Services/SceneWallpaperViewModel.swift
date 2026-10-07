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

class SceneWallpaperViewModel: ObservableObject {
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

    private var pkgParser: PKGParser?
    private var videoPlayer: AVQueuePlayer?
    private var videoLooper: AVPlayerLooper?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var readinessTimer: Timer?
    private var audioPlayers: [(AVAudioPlayer, Float)] = []
    private var temporaryDirectory: URL?
    private var cancellables = Set<AnyCancellable>()
    private var audioError: String?
    private var sleeping = false
    private var playRate: Float = 0
    private var playVolume: Float = 0
    private weak var fallbackNode: SKNode?
    private weak var errorNode: SKLabelNode?

    func stop() {
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
        videoPlayer?.volume = playVolume
        for (player, volume) in audioPlayers {
            player.volume = volume * playVolume
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


    init(wallpaper: WEWallpaper) {
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
        shared.$playVolume.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.playVolume = value
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
                scene = try parser.extractJSON(named: sceneFile, as: WEScene.self)
            } catch {
                loadError = error.localizedDescription
                Self.log("Failed to parse PKG: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: looseSceneURL.path(percentEncoded: false)) {
            // Loose files (no .pkg)
            self.pkgParser = nil
            do {
                let data = try Data(contentsOf: looseSceneURL)
                scene = try JSONDecoder().decode(WEScene.self, from: data)
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

        // Background color from clearcolor
        if let colorStr = scene.general.clearcolor {
            let c = colorStr.parseColor()
            skScene.backgroundColor = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
        }

        addFallback(to: skScene, wallpaperDir: wallpaperDir)
        // Select the largest visible image before loading any assets. A failed background
        // must not be mistaken for success merely because a small overlay decoded.
        let background = scene.objects.filter { $0.visible != false && $0.image != nil }.max {
            let a = ($0.size ?? "0 0").parseVector2()
            let b = ($1.size ?? "0 0").parseVector2()
            return a.0 * a.1 < b.0 * b.1
        }
        if let background = background {
            if !buildVideoNode(background, in: skScene, wallpaperDir: wallpaperDir) {
                if let node = buildImageNode(background, wallpaperDir: wallpaperDir) {
                    skScene.addChild(node)
                    fallbackNode?.isHidden = true
                } else {
                    reportFailure("Background unavailable: " + (background.name ?? background.image ?? "unknown"))
                }
            }
        } else {
            reportFailure("Scene contains no supported background")
        }

        // Preserve the existing static overlay support. Its success never hides fallback.
        for (index, object) in scene.objects.enumerated() where object.visible != false && object.image != nil && object.image != background?.image {
            if let node = buildImageNode(object, wallpaperDir: wallpaperDir), node.blendMode != .add {
                node.zPosition = CGFloat(index + 1)
                skScene.addChild(node)
            }
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
        if let data = pkgParser?.extractFile(named: path) { return Data(data) }
        return try? Data(contentsOf: wallpaperDir.appendingPathComponent(path))
    }

    private func buildVideoNode(_ object: WESceneObject, in scene: SKScene, wallpaperDir: URL) -> Bool {
        guard let modelPath = object.image,
              let model: WEModel = loadJSON(path: modelPath, wallpaperDir: wallpaperDir),
              let materialPath = model.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir),
              let name = material.passes?.first?.textures?.first else { return false }
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

        // Load model JSON → material JSON → texture
        let model: WEModel? = loadJSON(path: imagePath, wallpaperDir: wallpaperDir)
        guard let materialPath = model?.material else {
            print("[SceneVM] No material for image object '\(obj.name ?? "")' (model path: \(imagePath))")
            return nil
        }

        let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
        guard let textureName = material?.passes?.first?.textures?.first else {
            print("[SceneVM] No texture in material '\(materialPath)' (material decoded: \(material != nil))")
            return nil
        }

        // Load texture: try .tex file first, then common image formats
        Self.log("Loading texture '\(textureName)' for '\(obj.name ?? "")'")
        let image = loadTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir)
        guard let image = image else {
            Self.log("FAILED to load texture '\(textureName)' from material dir '\(materialPath)'")
            return nil
        }
        Self.log("Texture loaded: \(image.size)")

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
            node.colorBlendFactor = (obj.colorBlendMode ?? 0) > 0 ? 1.0 : 0.0
        }

        // Blend mode from material
        if let blending = material?.passes?.first?.blending {
            switch blending {
            case "additive": node.blendMode = .add
            case "translucent": node.blendMode = .alpha
            default: node.blendMode = .alpha
            }
        }

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
            if let texName = material?.passes?.first?.textures?.first {
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
                    return image
                }
                Self.log("  TEXParser.extractImage() returned nil for '\(texPath)'")
            }

            // Try .tex from loose file
            let texURL = wallpaperDir.appending(path: texPath)
            if let texData = try? Data(contentsOf: texURL) {
                let texParser = TEXParser(data: texData)
                if let image = texParser.extractImage() {
                    return image
                }
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
            // Generic soft circle
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)
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
