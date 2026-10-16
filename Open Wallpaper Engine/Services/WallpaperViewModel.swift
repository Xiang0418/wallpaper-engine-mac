//
//  WallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import SwiftUI
import Combine
import AVFoundation

/// Provide Wallpaper Database for WallpaperView and ContentView etc.
class WallpaperViewModel: ObservableObject {
    @Published var nextCurrentWallpaper: WEWallpaper =
    WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!) {
        willSet {
            if ["web", "application"].contains(newValue.project.type) {
                if let trustedWallpapers = UserDefaults.standard.array(forKey: "TrustedWallpapers") as? [String],
                   trustedWallpapers.contains(newValue.wallpaperDirectory.path(percentEncoded: false)) {
                    self.setWallpaper(newValue, for: selectedScreenId)
                } else {
                    AppDelegate.shared.contentViewModel.warningUnsafeWallpaperModal(which: newValue)
                }
            } else {
                self.setWallpaper(newValue, for: selectedScreenId)
            }
        }
    }

    /// Per-screen wallpaper assignments, keyed by persistent display UUID.
    @Published var wallpapers: [String: WEWallpaper] = [:] {
        didSet { saveWallpapers() }
    }

    @Published private(set) var loadingWallpapers: [String: String] = [:]
    @Published private(set) var wallpaperLoadErrors: [String: String] = [:]
    private var scenePreparations: [String: Task<Void, Never>] = [:]
    private var requestedDirectories: [String: URL] = [:]
    private var loadTickets: [String: UUID] = [:]
    private var preparedVideoPlayers: [String: AVPlayer] = [:]
    private var preparedScenes: [String: SceneWallpaperViewModel] = [:]
    func takePreparedVideoPlayer(for screenId: String) -> AVPlayer? {
        preparedVideoPlayers.removeValue(forKey: screenId)
    }
    func takePreparedScene(for screenId: String) -> SceneWallpaperViewModel? {
        preparedScenes.removeValue(forKey: screenId)
    }

    /// Screens where wallpaper display is enabled.
    @Published var enabledScreens: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(enabledScreens), forKey: "EnabledScreens")
        }
    }

    /// The screen currently selected in the UI for configuration.
    @Published var selectedScreenId: String = ""

    static let defaultWallpaper = WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!)

    // MARK: - Recent wallpapers

    private static let maxRecents = 10
    private static let recentsKey = "RecentWallpapers"

    @Published var recentWallpapers: [WEWallpaper] = []

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              let saved = try? JSONDecoder().decode([WEWallpaper].self, from: data) else { return }
        recentWallpapers = saved.filter { $0.project != .invalid }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentWallpapers) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    func addToRecents(_ wallpaper: WEWallpaper) {
        guard wallpaper.project != .invalid else { return }
        recentWallpapers.removeAll { $0.wallpaperDirectory == wallpaper.wallpaperDirectory }
        recentWallpapers.insert(wallpaper, at: 0)
        if recentWallpapers.count > Self.maxRecents {
            recentWallpapers = Array(recentWallpapers.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    // MARK: - Wallpaper access

    /// Convenience: wallpaper for the currently selected screen in the UI.
    var currentWallpaper: WEWallpaper {
        get {
            wallpapers[selectedScreenId] ?? Self.defaultWallpaper
        }
        set {
            setWallpaper(newValue, for: selectedScreenId)
        }
    }

    /// Get wallpaper for a specific screen.
    func wallpaper(for screenId: String) -> WEWallpaper {
        wallpapers[screenId] ?? Self.defaultWallpaper
    }

    /// Set wallpaper for a specific screen.
    func setWallpaper(_ wallpaper: WEWallpaper, for screenId: String, resolvePreset: Bool = true) {
        scenePreparations[screenId]?.cancel()
        requestedDirectories[screenId] = wallpaper.wallpaperDirectory
        let ticket = UUID()
        loadTickets[screenId] = ticket
        loadingWallpapers.removeValue(forKey: screenId)
        wallpaperLoadErrors.removeValue(forKey: screenId)
        if resolvePreset && wallpaper.project.dependency != nil {
            loadingWallpapers[screenId] = wallpaper.project.title
            scenePreparations[screenId] = Task { @MainActor [weak self] in
                do {
                    let resolved = try await WEPresetResolver.prepare(wallpaper)
                    guard let self, !Task.isCancelled, self.loadTickets[screenId] == ticket else { return }
                    self.scenePreparations.removeValue(forKey: screenId)
                    self.setWallpaper(resolved, for: screenId, resolvePreset: false)
                } catch {
                    guard let self, self.loadTickets[screenId] == ticket else { return }
                    self.loadingWallpapers.removeValue(forKey: screenId)
                    self.scenePreparations.removeValue(forKey: screenId)
                    self.wallpaperLoadErrors[screenId] = "Preset 載入失敗：" + error.localizedDescription
                }
            }
            return
        }
        let type = wallpaper.project.type.lowercased()
        guard type == "scene" || type == "video" else {
            wallpapers[screenId] = wallpaper; addToRecents(wallpaper); return
        }
        // Keep the committed assignment (and its live renderer) unchanged until ready.
        loadingWallpapers[screenId] = wallpaper.project.title ?? wallpaper.wallpaperDirectory.lastPathComponent
        let assets = EngineAssetLibrary.standard.activeRoot
        scenePreparations[screenId] = Task { @MainActor [weak self] in
            do {
                let prepared: SceneWallpaperViewModel?
                var videoPlayer: AVPlayer?
                if type == "scene" {
                    let token = DesktopLoadCancellation()
                    prepared = try await withTaskCancellationHandler {
                        try await SceneWallpaperViewModel.prepare(wallpaper: wallpaper, screenId: screenId,
                            assets: assets, cancelled: { token.isCancelled })
                    } onCancel: { token.cancel() }
                } else {
                    let asset = AVURLAsset(url: SceneAssetResolver.contentRoot(wallpaper.wallpaperDirectory).appendingPathComponent(wallpaper.project.file))
                    guard try await asset.load(.isPlayable) else {
                        throw NSError(domain: "WallpaperLoad", code: 1, userInfo: [NSLocalizedDescriptionKey: "影片無法播放"])
                    }
                    guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                        throw NSError(domain: "WallpaperLoad", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到影片畫面"])
                    }
                    let item = AVPlayerItem(asset: asset)
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = true
                    let deadline = ProcessInfo.processInfo.systemUptime + 30
                    while item.status != .readyToPlay {
                        try Task.checkCancellation()
                        guard item.status != .failed, ProcessInfo.processInfo.systemUptime < deadline else {
                            throw item.error ?? NSError(domain: "WallpaperLoad", code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "影片載入失敗或逾時"])
                        }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    videoPlayer = player
                    prepared = nil
                }
                guard let self, !Task.isCancelled, self.loadTickets[screenId] == ticket else {
                    prepared?.stop(); return
                }
                self.preparedScenes[screenId]?.stop()
                self.preparedScenes[screenId] = prepared
                self.preparedVideoPlayers[screenId] = videoPlayer
                self.wallpapers[screenId] = wallpaper
                self.addToRecents(wallpaper)
                self.loadingWallpapers.removeValue(forKey: screenId)
                self.scenePreparations.removeValue(forKey: screenId)
            } catch {
                guard let self, self.loadTickets[screenId] == ticket else { return }
                self.loadingWallpapers.removeValue(forKey: screenId)
                self.scenePreparations.removeValue(forKey: screenId)
                if !(error is CancellationError) {
                    self.wallpaperLoadErrors[screenId] = "載入失敗，保留原桌布：" + error.localizedDescription
                }
            }
        }
    }

    func isScreenEnabled(_ screenId: String) -> Bool {
        enabledScreens.contains(screenId)
    }

    func toggleScreen(_ screenId: String) {
        if enabledScreens.contains(screenId) {
            scenePreparations.removeValue(forKey: screenId)?.cancel()
            loadTickets.removeValue(forKey: screenId)
            loadingWallpapers.removeValue(forKey: screenId)
            preparedScenes.removeValue(forKey: screenId)?.stop()
            preparedVideoPlayers.removeValue(forKey: screenId)?.pause()
            enabledScreens.remove(screenId)
        } else {
            enabledScreens.insert(screenId)
        }
        AppDelegate.shared.rebuildWallpaperWindows()
    }

    /// Remove a wallpaper from all screens (e.g., when unsubscribing).
    func removeWallpaperFromAllScreens(directory: URL) {
        for (id, requested) in requestedDirectories where requested == directory {
            scenePreparations.removeValue(forKey: id)?.cancel()
            loadTickets.removeValue(forKey: id); loadingWallpapers.removeValue(forKey: id)
            preparedScenes.removeValue(forKey: id)?.stop()
            preparedVideoPlayers.removeValue(forKey: id)?.pause()
        }
        for (key, wp) in wallpapers {
            if wp.wallpaperDirectory == directory {
                wallpapers[key] = Self.defaultWallpaper
            }
        }
    }

    var lastPlayRate: Float = 1.0
    @Published public var playRate: Float = 1.0 {
        willSet {
            if newValue == 0.0 {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Pause" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: "Resume", systemImage: "play.fill", action: #selector(AppDelegate.shared.resume), keyEquivalent: "")
                    }
                }
            } else {
                for (index, item) in AppDelegate.shared.statusItem.menu!.items.enumerated() {
                    if item.title == "Resume" {
                        AppDelegate.shared.statusItem.menu!.items[index] =
                            .init(title: "Pause", systemImage: "pause.fill", action: #selector(AppDelegate.shared.pause), keyEquivalent: "")
                    }
                }
            }
        }
        didSet {
            self.lastPlayRate = oldValue
        }
    }

    // The master volume remains the global mute gate; wallpaper levels are independent.
    var lastPlayVolume: Float = 1.0
    @Published public var playVolume: Float = 1.0 {
        didSet {
            if oldValue > 0 { lastPlayVolume = oldValue }
            guard let menu = AppDelegate.shared.statusItem?.menu,
                  let item = menu.items.first(where: {
                      $0.action == #selector(AppDelegate.mute) || $0.action == #selector(AppDelegate.unmute)
                  }) else { return }
            item.title = playVolume == 0 ? String(localized: "Unmute") : String(localized: "Mute")
            item.action = playVolume == 0 ? #selector(AppDelegate.unmute) : #selector(AppDelegate.mute)
            item.image = NSImage(systemSymbolName: playVolume == 0 ? "speaker.fill" : "speaker.slash.fill", accessibilityDescription: nil)
        }
    }

    /// Audio routing is independent from the display selected for wallpaper editing.
    @Published private(set) var audioSourceScreenId: String

    func updateMainDisplayAudioSource(screenId: String? = nil) {
        audioSourceScreenId = screenId ?? Self.mainScreenId()
        WallpaperPlaybackSessions.shared.selectAudioSource(screenId: audioSourceScreenId)
    }

    private static let volumesKey = "WallpaperVolumeLevels"
    private let volumeDefaults: UserDefaults
    @Published private(set) var wallpaperVolumes: [String: Float] = [:]

    static func volumeKey(for wallpaper: WEWallpaper) -> String {
        wallpaper.wallpaperDirectory.standardizedFileURL.path
    }

    static func supportsVolume(_ wallpaper: WEWallpaper) -> Bool {
        wallpaper.project != .invalid && ["scene", "video"].contains(wallpaper.project.type.lowercased())
    }

    func volume(for wallpaper: WEWallpaper) -> Float {
        wallpaperVolumes[Self.volumeKey(for: wallpaper)] ?? 1
    }

    func setVolume(_ volume: Float, for wallpaper: WEWallpaper) {
        guard volume.isFinite else { return }
        let level = min(1, max(0, volume))
        let key = Self.volumeKey(for: wallpaper)
        guard wallpaperVolumes[key] != level else { return }
        wallpaperVolumes[key] = level
        volumeDefaults.set(wallpaperVolumes.mapValues { Double($0) }, forKey: Self.volumesKey)
    }

    func effectiveVolume(for wallpaper: WEWallpaper) -> Float {
        playVolume * volume(for: wallpaper)
    }

    func volumePublisher(for wallpaper: WEWallpaper) -> AnyPublisher<Float, Never> {
        let key = Self.volumeKey(for: wallpaper)
        return $playVolume.combineLatest($wallpaperVolumes)
            .map { master, levels in master * (levels[key] ?? 1) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    init(volumeDefaults: UserDefaults = .standard) {
        self.volumeDefaults = volumeDefaults
        audioSourceScreenId = Self.mainScreenId()
        wallpaperVolumes = (volumeDefaults.dictionary(forKey: Self.volumesKey) ?? [:])
            .compactMapValues { value in
                guard let number = value as? NSNumber, number.floatValue.isFinite else { return nil }
                return min(1, max(0, number.floatValue))
            }
        // Load per-screen wallpapers
        if let data = UserDefaults.standard.data(forKey: "ScreenWallpapers"),
           let saved = try? JSONDecoder().decode([String: WEWallpaper].self, from: data) {
            // Filter out any compound keys (screenId_spaceId) from previous per-space experiment
            self.wallpapers = saved.filter { !$0.key.contains("_") }
        }
        // Migrate legacy single wallpaper
        else if let json = UserDefaults.standard.data(forKey: "CurrentWallpaper"),
                let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: json) {
            let mainId = Self.mainScreenId()
            self.wallpapers = [mainId: wallpaper]
        }

        // Load enabled screens (default: all connected screens enabled)
        if let saved = UserDefaults.standard.array(forKey: "EnabledScreens") as? [String] {
            self.enabledScreens = Set(saved)
        } else {
            self.enabledScreens = Set(NSScreen.screens.map { Self.screenId(for: $0) })
        }

        // Migrate session-specific numeric IDs to hardware display UUIDs.
        for screen in NSScreen.screens {
            let legacy = String(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0)
            let stable = Self.screenId(for: screen)
            if legacy != stable {
                if let wallpaper = wallpapers.removeValue(forKey: legacy), wallpapers[stable] == nil { wallpapers[stable] = wallpaper }
                if enabledScreens.remove(legacy) != nil { enabledScreens.insert(stable) }
            }
        }

        // Default selected screen to main
        self.selectedScreenId = Self.mainScreenId()

        saveWallpapers()
        UserDefaults.standard.set(Array(enabledScreens), forKey: "EnabledScreens")

        // Load recent wallpapers
        loadRecents()
        WallpaperPlaybackSessions.shared.selectAudioSource(screenId: audioSourceScreenId)
    }

    // MARK: - Screen ID helpers

    static func screenId(for screen: NSScreen) -> String {
        let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return stableScreenId(displayId)
    }

    static func mainScreenId() -> String {
        // NSScreen.main follows keyboard focus; CGMainDisplayID is the system primary display.
        stableScreenId(CGMainDisplayID())
    }

    private static func stableScreenId(_ displayId: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayId)?.takeRetainedValue() else { return String(displayId) }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screenName(for screen: NSScreen) -> String {
        screen.localizedName
    }

    // MARK: - Persistence

    private func saveWallpapers() {
        if let data = try? JSONEncoder().encode(wallpapers) {
            UserDefaults.standard.set(data, forKey: "ScreenWallpapers")
        }
        // Keep legacy key updated for backward compat
        if let data = try? JSONEncoder().encode(currentWallpaper) {
            UserDefaults.standard.set(data, forKey: "CurrentWallpaper")
        }
    }
}


private final class DesktopLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
