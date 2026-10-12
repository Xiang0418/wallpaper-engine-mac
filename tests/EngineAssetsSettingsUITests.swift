import AppKit
import SwiftUI

extension FileManager {
    var wallpapersDirectory: URL { temporaryDirectory.appendingPathComponent("unused-assets-ui-wallpapers") }
}
@main struct EngineAssetsSettingsUITests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assets-ui-" + UUID().uuidString)
        let assets = EngineAssetsService(library: EngineAssetLibrary(root: root))
        let steam = SteamCmdService(startAutomatically: false)
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: Form {
                EngineAssetsSettingsSection(assets: assets, steam: steam)
                Section {
                    EngineAssetProgressView(progress: EngineAssetProgress(phase: .downloading, fraction: 0.425,
                        completedBytes: 425_000_000, totalBytes: 1_000_000_000))
                }
            }
                .formStyle(.grouped).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let path = "/tmp/we-assets-settings-\(scheme == .dark ? "dark" : "light").png"
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            window.orderOut(nil)
            print(path)
        }
    }
}
