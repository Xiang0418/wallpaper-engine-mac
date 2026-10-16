import Foundation
import Combine

extension FileManager {
    var wallpapersDirectory: URL { temporaryDirectory.appendingPathComponent("unused-workshop-test-library") }
}

@main struct WorkshopImportTests {
    static func main() async throws {
        try await Task.detached {
            precondition(!Thread.isMainThread)
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("workshop-import-" + UUID().uuidString)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            let source = root.appendingPathComponent("source")
            let dest = root.appendingPathComponent("destination")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            let data = Data(repeating: 42, count: 1024 * 1024)
            try data.write(to: source.appendingPathComponent("wallpaper.bin"))
            try SteamCmdService.importWorkshopItem(from: source, to: dest)
            let copied = try Data(contentsOf: dest.appendingPathComponent("wallpaper.bin"))
            precondition(copied == data)
            try Data([1]).write(to: source.appendingPathComponent("wallpaper.bin"))
            try SteamCmdService.importWorkshopItem(from: source, to: dest)
            let preserved = try Data(contentsOf: dest.appendingPathComponent("wallpaper.bin"))
            precondition(preserved == data, "Existing library contents must be preserved")
            let failedDest = root.appendingPathComponent("failed")
            do {
                try SteamCmdService.importWorkshopItem(from: root.appendingPathComponent("missing"), to: failedDest)
                fatalError("Missing source must fail")
            } catch {}
            precondition(!fm.fileExists(atPath: failedDest.path))
            let leftovers = try fm.contentsOfDirectory(atPath: root.path)
            precondition(!leftovers.contains { $0.hasPrefix(".import-") }, "Staging must be cleaned up")
        }.value
        print("PASS: background import, byte integrity, existing item preservation, failure cleanup")
    }
}
