//
//  VideoWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import AVKit
import SwiftUI
import Combine

class VideoWallpaperViewModel: ObservableObject, WallpaperPlaybackSession {
    private let screenId: String
    private var audioEnabled = true
    private var sleepReasons = Set<String>()
    private var policyPaused = false
    private var policyMuted = false
    private var effectiveRate: Float { sleepReasons.isEmpty && !policyPaused ? playRate : 0 }
    func setPlaybackPolicy(paused: Bool, muted: Bool) {
        policyPaused = paused; policyMuted = muted
        player.rate = effectiveRate
        player.volume = audioEnabled && !policyMuted ? playVolume : 0
    }

    func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        player.volume = enabled && !policyMuted ? playVolume : 0
    }
    func stop() {
        WallpaperPlaybackSessions.shared.unregister(self, screenId: screenId)
        volumeSubscription = nil
        cancellables.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    private func registerPlayback() {
        WallpaperPlaybackSessions.shared.register(self, screenId: screenId)
    }

    var currentWallpaper: WEWallpaper {
        didSet {
            observeVolume()
            // Remove observer for old item before replacing
            if let oldItem = self.player.currentItem {
                NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
            }
            let newItem: AVPlayerItem
            if let prepared = AppDelegate.shared.wallpaperViewModel.takePreparedVideoPlayer(for: screenId),
               let item = prepared.currentItem {
                player.pause()
                player = prepared
                player.isMuted = false
                newItem = item
            } else {
                newItem = AVPlayerItem(url: SceneAssetResolver.contentRoot(currentWallpaper.wallpaperDirectory).appending(path: currentWallpaper.project.file))
                self.player.replaceCurrentItem(with: newItem)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: newItem)
            // Force-apply rate and volume — replaceCurrentItem resets player to paused
            self.player.rate = effectiveRate
            registerPlayback()
            self.player.volume = audioEnabled && !policyMuted ? self.playVolume : 0
        }
    }

    var playRate: Float = 0 {
        didSet {
            self.player.rate = effectiveRate
        }
    }

    var playVolume: Float = 0 {
        didSet {
            self.player.volume = audioEnabled && !policyMuted ? playVolume : 0
        }
    }

    var player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var volumeSubscription: AnyCancellable?

    init(wallpaper currentWallpaper: WEWallpaper, screenId: String = UUID().uuidString, preparedPlayer: AVPlayer? = nil) {
        self.screenId = screenId
        self.currentWallpaper = currentWallpaper
        self.player = preparedPlayer ?? AVPlayer(url: SceneAssetResolver.contentRoot(currentWallpaper.wallpaperDirectory).appending(path: currentWallpaper.project.file))
        self.player.isMuted = false
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: self.player.currentItem)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Directly observe playRate/playVolume changes from the shared WallpaperViewModel
        let wvm = AppDelegate.shared.wallpaperViewModel
        wvm.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.playRate = rate
            }
            .store(in: &cancellables)
        observeVolume()
        registerPlayback()
    }

    private func observeVolume() {
        volumeSubscription = AppDelegate.shared.wallpaperViewModel.volumePublisher(for: currentWallpaper)
            .sink { [weak self] volume in self?.playVolume = volume }
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        // Replay video
        self.player.seek(to: CMTime.zero)
        self.player.rate = effectiveRate
    }

    @objc private func playerDidStopPlaying(_ notification: Notification) {
        // Resume playback
        self.player.rate = effectiveRate
    }

    @objc func systemWillSleep(_ notification: Notification) {
        sleepReasons.insert(notification.name == NSWorkspace.willSleepNotification ? "system" : "display")
        self.player.rate = 0
    }

    @objc func systemDidWake(_ notification: Notification) {
        sleepReasons.remove(notification.name == NSWorkspace.didWakeNotification ? "system" : "display")
        self.player.rate = effectiveRate
    }
}
