import AppKit
import Combine
import SpriteKit

protocol ExternalAudioCapturing: AnyObject {
    var statusChanged: ((String) -> Void)? { get set }
    func setEnabled(_ value: Bool, retry: Bool)
    func snapshot() -> [Float]
}
extension SystemAudioCapture: ExternalAudioCapturing {}

protocol NowPlayingReading: AnyObject {
    var received: ((NowPlayingSnapshot, CGImage?) -> Void)? { get set }
    var failed: (() -> Void)? { get set }
    func start()
    func stop()
}
extension NowPlayingBridge: NowPlayingReading {}

/// Shared by all scene wallpapers and the settings page. Preference keys are
/// separate from legacy Codable settings so existing saved settings still load.
final class ExternalMediaService: ObservableObject {
    static let shared = ExternalMediaService()
    @Published var artworkEnabled: Bool {
        didSet { defaults.set(artworkEnabled, forKey: "ExternalMedia.artwork"); reconcile() }
    }
    @Published var systemAudioEnabled: Bool {
        didSet { defaults.set(systemAudioEnabled, forKey: "ExternalMedia.audio"); reconcile() }
    }
    @Published private(set) var artworkStatus = String(localized: "Album artwork is off")
    @Published private(set) var audioStatus = String(localized: "External audio is off")
    @Published private(set) var trackTitle = ""
    private(set) var artworkTexture: SKTexture?
    private(set) var artworkRevision = 0
    private let defaults: UserDefaults
    private let bridge: NowPlayingReading
    private let audio: ExternalAudioCapturing
    private var consumers = Set<UUID>()
    private var artworkRunning = false
    private var audioRunning = false
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    private var artworkData: Data?

    init(defaults: UserDefaults = .standard, bridge: NowPlayingReading = NowPlayingBridge(), audio: ExternalAudioCapturing = SystemAudioCapture()) {
        self.defaults = defaults; self.bridge = bridge; self.audio = audio
        artworkEnabled = defaults.bool(forKey: "ExternalMedia.artwork")
        systemAudioEnabled = defaults.bool(forKey: "ExternalMedia.audio")
        bridge.received = { [weak self] snapshot, image in
            guard let self else { return }
            self.trackTitle = [snapshot.title, snapshot.artist].filter { !$0.isEmpty }.joined(separator: " — ")
            if snapshot.artwork != self.artworkData {
                self.artworkData = snapshot.artwork
                self.artworkTexture = image.map { SKTexture(cgImage: $0) }
                self.artworkRevision += 1
            }
            self.artworkStatus = snapshot.title.isEmpty ? String(localized: "Waiting for a player") :
                image == nil ? String(localized: "Player has no album artwork") :
                snapshot.playing ? String(localized: "Album artwork connected") : String(localized: "Player paused — keeping album artwork")
        }
        bridge.failed = { [weak self] in
            self?.clearArtwork()
            self?.artworkStatus = String(localized: "Album artwork unavailable. The media bridge may be incompatible with this macOS version. Retry after updating the app.")
        }
        audio.statusChanged = { [weak self] status in
            guard let self, self.audioRunning else { return }
            self.audioStatus = status
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true; self?.reconcile()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false; self?.reconcile()
        })
    }

    func setConsumer(_ id: UUID, active: Bool) {
        if active { consumers.insert(id) } else { consumers.remove(id) }
        reconcile()
    }

    func spectrum() -> [Float] { audio.snapshot() }

    /// System capture excludes this app, so retain the wallpaper's own audio.
    func spectrum(wallpaper: [Float]) -> [Float] {
        guard systemAudioEnabled else { return wallpaper }
        let external = audio.snapshot()
        return wallpaper.enumerated().map { index, value in
            min(1, value + (index < external.count ? external[index] : 0))
        }
    }

    func shutdown() { consumers.removeAll(); reconcile() }

    func retry() {
        if artworkRunning { bridge.stop(); bridge.start() }
        if audioRunning { audio.setEnabled(true, retry: true) }
    }

    private func clearArtwork() {
        artworkData = nil; artworkTexture = nil; artworkRevision += 1; trackTitle = ""
    }

    private func reconcile() {
        let active = !sleeping && !consumers.isEmpty
        let wantsArtwork = active && artworkEnabled
        if wantsArtwork != artworkRunning {
            artworkRunning = wantsArtwork
            if wantsArtwork { artworkStatus = String(localized: "Waiting for a player"); bridge.start() }
            else { bridge.stop(); clearArtwork() }
        }
        let wantsAudio = active && systemAudioEnabled
        if wantsAudio != audioRunning { audioRunning = wantsAudio; audio.setEnabled(wantsAudio, retry: false) }
        if !artworkEnabled { artworkStatus = String(localized: "Album artwork is off") }
        else if !active { artworkStatus = String(localized: "Waiting for an active scene wallpaper") }
        if !systemAudioEnabled { audioStatus = String(localized: "External audio is off") }
        else if !active { audioStatus = String(localized: "Waiting for an active scene wallpaper") }
    }

    deinit {
        bridge.stop(); audio.setEnabled(false, retry: false)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
