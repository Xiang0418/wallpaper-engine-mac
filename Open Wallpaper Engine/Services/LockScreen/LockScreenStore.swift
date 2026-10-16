import Foundation
import CryptoKit

struct LockScreenFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// File operations are independent of AppKit and testable in a temporary directory.
final class LockScreenStore {
    struct Manifest: Codable {
        var slot: String
        var originalHash: String
        var settingsHash: String
        var installedHash: String?
        var pendingHash: String?
    }
    let root: URL
    let videos: URL
    let settings: URL
    private let fm = FileManager.default
    var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    var originalURL: URL { root.appendingPathComponent("original.mov") }
    var settingsBackup: URL { root.appendingPathComponent("Index.original.plist") }
    var hasBackup: Bool { fm.fileExists(atPath: manifestURL.path) }

    init(root: URL, videos: URL, settings: URL) {
        self.root = root; self.videos = videos; self.settings = settings
    }
    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func manifest() throws -> Manifest { try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
    private func save(_ m: Manifest) throws { try JSONEncoder().encode(m).write(to: manifestURL, options: .atomic) }
    func slotURL(_ m: Manifest) throws -> URL {
        guard UUID(uuidString: m.slot) != nil else { throw LockScreenFailure("Invalid Aerial backup identifier.") }
        return videos.appendingPathComponent(m.slot).appendingPathExtension("mov")
    }
    func prepare() throws -> URL {
        if hasBackup { return try slotURL(manifest()) }
        let slots = try fm.contentsOfDirectory(at: videos, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard slots.count == 1, let slot = slots.first else {
            throw LockScreenFailure("Download one Apple aerial in System Settings first. Multiple downloaded aerials require selecting a slot before setup.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Never overwrite an incomplete backup after a failed first setup.
        guard !fm.fileExists(atPath: originalURL.path), !fm.fileExists(atPath: settingsBackup.path) else {
            throw LockScreenFailure("An incomplete backup exists. Open the backup folder before retrying.")
        }
        let originalHash = try Self.hash(slot), settingsHash = try Self.hash(settings)
        try fm.copyItem(at: slot, to: originalURL)
        try fm.copyItem(at: settings, to: settingsBackup)
        guard try Self.hash(originalURL) == originalHash, try Self.hash(settingsBackup) == settingsHash else {
            throw LockScreenFailure("Backup verification failed. No wallpaper was replaced.")
        }
        try save(Manifest(slot: slot.deletingPathExtension().lastPathComponent,
                          originalHash: originalHash, settingsHash: settingsHash))
        return slot
    }
    func verifyBackup(_ m: Manifest) throws {
        guard try Self.hash(originalURL) == m.originalHash, try Self.hash(settingsBackup) == m.settingsHash else {
            throw LockScreenFailure("Backup verification failed. Restore was stopped.")
        }
    }
    func install(_ movie: URL) throws {
        _ = try prepare()
        var m = try manifest()
        try verifyBackup(m)
        let slot = try slotURL(m), current = try Self.hash(slot)
        guard [m.originalHash, m.installedHash, m.pendingHash].compactMap({ $0 }).contains(current) else {
            throw LockScreenFailure("The aerial was changed by another app or macOS. It was not overwritten.")
        }
        let next = try Self.hash(movie)
        m.pendingHash = next
        try save(m) // Recoverable even if the process exits immediately after replacement.
        try replace(movie, at: slot)
        guard try Self.hash(slot) == next else { throw LockScreenFailure("Installed movie verification failed.") }
        m.installedHash = next; m.pendingHash = nil
        try save(m)
    }
    func restore() throws {
        guard hasBackup else { return }
        var m = try manifest()
        try verifyBackup(m)
        let slot = try slotURL(m), current = try Self.hash(slot)
        guard [m.originalHash, m.installedHash, m.pendingHash].compactMap({ $0 }).contains(current) else {
            throw LockScreenFailure("The aerial has changed outside this app. Restore stopped to preserve that change.")
        }
        try replace(originalURL, at: slot)
        try replace(settingsBackup, at: settings)
        m.installedHash = nil; m.pendingHash = nil
        try save(m)
    }
    private func replace(_ source: URL, at target: URL) throws {
        let temp = target.deletingLastPathComponent().appendingPathComponent(".owe-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(at: source, to: temp)
        _ = try fm.replaceItemAt(target, withItemAt: temp)
    }
}
