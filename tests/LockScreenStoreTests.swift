import Foundation

@main struct LockScreenStoreTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let videos = root.appendingPathComponent("videos")
        try fm.createDirectory(at: videos, withIntermediateDirectories: true)
        let settings = root.appendingPathComponent("Index.plist")
        let slot = videos.appendingPathComponent(UUID().uuidString + ".mov")
        let movie = root.appendingPathComponent("new.mov")
        try Data("original".utf8).write(to: slot)
        try Data("settings".utf8).write(to: settings)
        try Data("first".utf8).write(to: movie)
        let store = LockScreenStore(root: root.appendingPathComponent("backup"), videos: videos, settings: settings)
        try store.install(movie)
        try check(String(contentsOf: slot, encoding: .utf8) == "first")
        try Data("second".utf8).write(to: movie)
        try store.install(movie)
        try check(String(contentsOf: store.originalURL, encoding: .utf8) == "original")
        try Data("changed settings".utf8).write(to: settings)
        try store.restore()
        try check(String(contentsOf: slot, encoding: .utf8) == "original")
        try check(String(contentsOf: settings, encoding: .utf8) == "settings")
        try check(store.manifest().installedHash == nil)
        try store.install(movie)
        // Simulate exit after atomic replacement and before manifest commit.
        var manifest = try store.manifest()
        manifest.pendingHash = manifest.installedHash; manifest.installedHash = nil
        try JSONEncoder().encode(manifest).write(to: store.manifestURL)
        try store.restore()
        try Data("external edit".utf8).write(to: slot)
        try expectFailure { try store.install(movie) }
        try expectFailure { try store.restore() }
        try check(String(contentsOf: slot, encoding: .utf8) == "external edit")
        try Data("original".utf8).write(to: slot)
        try Data("corrupt backup".utf8).write(to: store.originalURL)
        try expectFailure { try store.restore() }
        try check(String(contentsOf: slot, encoding: .utf8) == "original")
        print("PASS: backup, repeated installation, restore, interrupted commit, external conflict, corrupt backup")
    }
    static func check(_ value: @autoclosure () throws -> Bool) throws {
        guard try value() else { fatalError("Assertion failed") }
    }
    static func expectFailure(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        fatalError("Expected failure")
    }
}
