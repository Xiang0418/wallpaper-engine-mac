import AppKit
import Combine
import SpriteKit

protocol ExternalAudioCapturing: AnyObject {
    var statusChanged: ((String) -> Void)? { get set }
    func setEnabled(_ value: Bool, retry: Bool)
    func snapshot() -> [Float]
}
extension SystemAudioCapture: ExternalAudioCapturing {}

/// Shared by all scene wallpapers and the settings page. Preference keys are
/// separate from legacy Codable settings so existing saved settings still load.
final class ExternalAudioService: ObservableObject {
    static let shared = ExternalAudioService()
    @Published var systemAudioEnabled: Bool {
        didSet { defaults.set(systemAudioEnabled, forKey: "ExternalMedia.audio"); reconcile() }
    }
    @Published private(set) var audioStatus = String(localized: "External audio is off")
    private let defaults: UserDefaults
    private let audio: ExternalAudioCapturing
    private var consumers = Set<UUID>()
    private var audioRunning = false
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, audio: ExternalAudioCapturing = SystemAudioCapture()) {
        self.defaults = defaults; self.audio = audio
        systemAudioEnabled = defaults.bool(forKey: "ExternalMedia.audio")
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

    func shutdown() { consumers.removeAll(); reconcile() }

    func retry() {
        if audioRunning { audio.setEnabled(true, retry: true) }
    }

    private func reconcile() {
        let active = !sleeping && !consumers.isEmpty
        let wantsAudio = active && systemAudioEnabled
        if wantsAudio != audioRunning { audioRunning = wantsAudio; audio.setEnabled(wantsAudio, retry: false) }
        if !systemAudioEnabled { audioStatus = String(localized: "External audio is off") }
        else if !active { audioStatus = String(localized: "Waiting for an active scene wallpaper") }
    }

    deinit {
        audio.setEnabled(false, retry: false)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
