import AppKit
import SwiftUI

@main struct ArtworkSettingsUITests {
    static func main() {
        _ = NSApplication.shared
        let suite = "ArtworkSettingsUI." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let media = NowPlayingArtworkService(defaults: defaults)
        media.artworkEnabled = true
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: Form { NowPlayingArtworkSettingsSection(media: media) }
                .formStyle(.grouped).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let path = "/tmp/we-artwork-settings-\(scheme == .dark ? "dark" : "light").png"
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            window.orderOut(nil)
            print(path)
        }
    }
}
