import Foundation

@main struct SceneAssetTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("scene-assets-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("local/materials/image.png", "local")
        try write("shared/materials/image.tex", "shared")
        try write("shared/Models/Solid.json", "{}")
        try write("shared/shaders/image.frag", "shader")
        func package(_ path: String, _ contents: String) throws -> PKGParser {
            var data = Data()
            func u32(_ value: Int) { var value = UInt32(value).littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            u32(8); data.append(Data("PKGV0013".utf8)); u32(1)
            u32(path.utf8.count); data.append(Data(path.utf8)); u32(0); u32(contents.utf8.count); data.append(Data(contents.utf8))
            return try PKGParser(data: data)
        }
        let local = root.appendingPathComponent("local"), shared = root.appendingPathComponent("shared")
        let resolver = SceneAssetResolver(wallpaperRoot: local, package: nil, sharedRoot: shared)
        precondition(resolver.asset(candidates: ["materials/image.tex", "materials/image.png"])?.data == Data("local".utf8), "Local overrides shared across extensions")
        precondition(resolver.data("models\\solid.json") == Data("{}".utf8), "Windows separators and case are supported")
        let packed = SceneAssetResolver(wallpaperRoot: local, package: try package("Materials\\Image.PNG", "package"), sharedRoot: shared)
        precondition(packed.asset(candidates: ["materials/image.tex", "materials/image.png"])?.data == Data("package".utf8))
        _ = resolver.asset(candidates: ["absent.tex", "models/solid.json"], required: true)
        precondition(resolver.issues.isEmpty, "Candidate misses are not failures")
        _ = resolver.data("missing.json", required: true); _ = resolver.data("missing.json", required: true)
        precondition(resolver.issues.count == 1 && resolver.issues[0].kind == .missing)
        for path in ["../shared/shaders/image.frag", "/etc/passwd", "C:\\Windows\\x", "models/../../x"] {
            precondition(resolver.data(path, required: true) == nil)
        }
        try fm.createSymbolicLink(at: local.appendingPathComponent("outside"), withDestinationURL: shared)
        precondition(resolver.data("outside/shaders/image.frag") == nil, "Symlink escapes are rejected")
        let library = EngineAssetLibrary(root: root.appendingPathComponent("library"))
        let first = try library.importFolder(shared)
        let firstRoot = library.activeRoot!
        precondition(first.fileCount == 3)
        try write("shared/materials/image.tex", "updated")
        let copied = try Data(contentsOf: firstRoot.appendingPathComponent("materials/image.tex"))
        precondition(copied == Data("shared".utf8), "Import is a copy")
        do { _ = try library.importFolder(local); fatalError("Invalid assets accepted") } catch {}
        precondition(library.manifest?.snapshot == first.snapshot, "Failed import preserves active snapshot")
        let second = try library.importFolder(shared)
        precondition(second.snapshot != first.snapshot && library.activeRoot != firstRoot)
        precondition(fm.fileExists(atPath: firstRoot.path), "Existing scenes can finish reading old snapshot")
        try fm.createSymbolicLink(at: shared.appendingPathComponent("link"), withDestinationURL: local)
        do { _ = try library.importFolder(shared); fatalError("Symlink import accepted") } catch {}
        precondition(library.manifest?.snapshot == second.snapshot)
        print("Shared assets: source precedence, Windows paths, diagnostics, confinement, import isolation and rollback passed")
    }
}
