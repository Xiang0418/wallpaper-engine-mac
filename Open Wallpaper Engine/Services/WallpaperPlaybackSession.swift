import Foundation

protocol WallpaperPlaybackSession: AnyObject {
    func stop()
    func setPlaybackPolicy(paused: Bool, muted: Bool)
    func setAudioEnabled(_ enabled: Bool)
}

extension WallpaperPlaybackSession {
    func setPlaybackPolicy(paused: Bool, muted: Bool) {}
}

/// One live renderer per screen, and only the selected screen may emit audio.
/// Called on the main thread by wallpaper views and display notifications.
final class WallpaperPlaybackSessions {
    static let shared = WallpaperPlaybackSessions()
    private struct Entry {
        weak var session: WallpaperPlaybackSession?
    }
    private var entries: [String: Entry] = [:]
    private var audioSourceScreenId: String?
    private var policyPaused = false
    private var policyMuted = false

    func setPlaybackPolicy(paused: Bool, muted: Bool) {
        policyPaused = paused; policyMuted = muted
        entries.values.forEach { $0.session?.setPlaybackPolicy(paused: paused, muted: muted) }
    }


    func selectAudioSource(screenId: String?) {
        audioSourceScreenId = screenId
        refreshAudioOwners()
    }

    func register(_ session: WallpaperPlaybackSession, screenId: String) {
        if let old = entries.removeValue(forKey: screenId)?.session, old !== session {
            old.stop()
        }
        session.setPlaybackPolicy(paused: policyPaused, muted: policyMuted)
        entries[screenId] = Entry(session: session)
        refreshAudioOwners()
    }

    func unregister(_ session: WallpaperPlaybackSession, screenId: String) {
        guard let entry = entries[screenId], entry.session == nil || entry.session === session else { return }
        entries.removeValue(forKey: screenId)
        refreshAudioOwners()
    }

    func stop(screenId: String) {
        let old = entries.removeValue(forKey: screenId)?.session
        old?.stop()
        refreshAudioOwners()
    }

    private func refreshAudioOwners() {
        entries = entries.filter { $0.value.session != nil }
        // Silence previous owners before enabling replacements to avoid overlap.
        entries.values.forEach { $0.session?.setAudioEnabled(false) }
        // A missing selected display stays silent instead of switching sources unexpectedly.
        let source = audioSourceScreenId ?? entries.keys.sorted().first
        if let source = source { entries[source]?.session?.setAudioEnabled(true) }
    }
}
