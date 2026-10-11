import AppKit
import Combine
import SpriteKit

protocol NowPlayingReading: AnyObject {
    var received: ((NowPlayingSnapshot, CGImage?) -> Void)? { get set }
    var failed: (() -> Void)? { get set }
    func start()
    func stop()
}
extension NowPlayingBridge: NowPlayingReading {}

/// Shared by all scene wallpapers and the settings page. Preference keys are
/// separate from legacy Codable settings so existing saved settings still load.
final class NowPlayingArtworkService: ObservableObject {
    static let shared = NowPlayingArtworkService()
    @Published var artworkEnabled: Bool {
        didSet { defaults.set(artworkEnabled, forKey: "ExternalMedia.artwork"); reconcile() }
    }
    @Published private(set) var artworkStatus = String(localized: "Album artwork is off")
    @Published private(set) var trackTitle = ""
    private(set) var artworkTexture: SKTexture?
    private(set) var artworkRevision = 0
    private let defaults: UserDefaults
    private let bridge: NowPlayingReading
    private var consumers = Set<UUID>()
    private var artworkRunning = false
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    private var artworkData: Data?

    init(defaults: UserDefaults = .standard, bridge: NowPlayingReading = NowPlayingBridge()) {
        self.defaults = defaults; self.bridge = bridge
        artworkEnabled = defaults.bool(forKey: "ExternalMedia.artwork")
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


    func shutdown() { consumers.removeAll(); reconcile() }

    func retry() {
        if artworkRunning { bridge.stop(); bridge.start() }
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
        if !artworkEnabled { artworkStatus = String(localized: "Album artwork is off") }
        else if !active { artworkStatus = String(localized: "Waiting for an active scene wallpaper") }
    }

    deinit {
        bridge.stop()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
