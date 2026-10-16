import Foundation
extension URL { func directoryTotalAllocatedSize(includingSubfolders: Bool) throws -> Int? { 0 } }
@main struct PresetResolverTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("preset-resolver-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); WEPresetResolver.downloadDependency = nil }
        func write(_ id: String, _ json: String) throws -> URL {
            let dir = root.appendingPathComponent(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
            return dir
        }
        func wallpaper(_ dir: URL) throws -> WEWallpaper {
            WEWallpaper(using: try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: dir.appendingPathComponent("project.json"))), where: dir)
        }
        let base = try write("1", #"{"file":"scene.json","type":"scene","title":"Base","preview":"preview.png","general":{"properties":{"color":{"type":"color","value":"1 0 0"},"flag":{"type":"bool","value":true},"count":{"type":"slider","value":2}}}}"#)
        try Data("base".utf8).write(to: base.appendingPathComponent("asset.txt"))
        let mid = try write("2", #"{"dependency":1,"title":"Middle","preview":"preview.png","preset":{"color":"0 1 0","count":8}}"#)
        let leaf = try write("3", #"{"dependency":"2","title":"Leaf","preview":"preview.png","preset":{"flag":false,"color":null,"count":0,"unknown":99}}"#)
        try Data("leaf".utf8).write(to: leaf.appendingPathComponent("asset.txt"))
        let resolved = try await WEPresetResolver.prepare(wallpaper(leaf))
        precondition(resolved.project.title == "Leaf" && resolved.project.type == "scene")
        let json = try WEPresetResolver.metadata(leaf.appendingPathComponent(".preset-runtime"))
        let props = (json["general"] as! [String: Any])["properties"] as! [String: [String: Any]]
        precondition(props["color"]?["value"] as? String == "0 1 0")
        precondition(props["flag"]?["value"] as? Bool == false && props["count"]?["value"] as? Int == 0)
        precondition(props["unknown"] == nil)
        let asset = try String(contentsOf: leaf.appendingPathComponent(".preset-runtime/asset.txt"))
        precondition(asset == "leaf")
        let unchanged = try String(contentsOf: base.appendingPathComponent("asset.txt"))
        precondition(unchanged == "base")
        print("PASS: nested presets, numeric IDs, false/zero/null values, asset precedence and source isolation")
        let missing = try write("4", #"{"dependency":"9","title":"Missing","preview":"p.png","preset":{}}"#)
        do { _ = try await WEPresetResolver.prepare(wallpaper(missing)); fatalError("Missing dependency accepted") }
        catch { precondition(error.localizedDescription.contains("9")) }
        WEPresetResolver.downloadDependency = { id, destination in
            precondition(id == "9")
            try fm.copyItem(at: base, to: destination)
        }
        let downloaded = try await WEPresetResolver.prepare(wallpaper(missing))
        precondition(downloaded.project.type == "scene")
        print("PASS: missing dependency error and on-demand dependency fetch")
        _ = try write("2", #"{"dependency":"3","title":"Cycle","preview":"p.png"}"#)
        do { _ = try await WEPresetResolver.prepare(wallpaper(leaf)); fatalError("Cycle accepted") }
        catch { precondition(error.localizedDescription.contains("cycle")) }
        _ = try write("2", #"{"dependency":"../1","title":"Unsafe","preview":"p.png"}"#)
        do { _ = try await WEPresetResolver.prepare(wallpaper(mid)); fatalError("Unsafe ID accepted") }
        catch { precondition(error.localizedDescription.contains("Invalid")) }
        let broken = try write("5", #"{"title":"Broken","preview":"p.png"}"#)
        do { _ = try wallpaper(broken); fatalError("Incomplete non-preset accepted") } catch {}
        print("PASS: cycles, traversal IDs and malformed ordinary projects rejected")
    }
}
