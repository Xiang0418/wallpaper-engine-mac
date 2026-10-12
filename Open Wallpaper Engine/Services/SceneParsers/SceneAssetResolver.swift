import Foundation
import Combine

struct SceneAssetIssue: Hashable {
    enum Kind: String { case missing, invalid, unsupported, approximate }
    let kind: Kind
    let path: String
    let detail: String
}

/// Reports are scoped to a playback session so multiple displays cannot overwrite each other.
final class SceneAssetDiagnostics: ObservableObject {
    static let shared = SceneAssetDiagnostics()
    struct Report {
        let wallpaper: String
        let issues: [SceneAssetIssue]
    }
    @Published private(set) var reports: [UUID: Report] = [:]
    func update(_ id: UUID, wallpaper: String, issues: [SceneAssetIssue]) {
        reports[id] = Report(wallpaper: wallpaper, issues: issues)
    }
    func remove(_ id: UUID) { reports.removeValue(forKey: id) }
}

/// One resolver per scene load. Candidate searches are silent until all alternatives fail.
final class SceneAssetResolver {
    struct Asset { let path: String; let data: Data }
    let wallpaperRoot: URL
    let sharedRoot: URL?
    private let package: PKGParser?
    private var packagePaths: [String: String] = [:]
    private var diskPaths: [String: URL] = [:]
    private(set) var issues: [SceneAssetIssue] = []
    var didReport: (([SceneAssetIssue]) -> Void)?

    init(wallpaperRoot: URL, package: PKGParser?, sharedRoot: URL?) {
        self.wallpaperRoot = wallpaperRoot
        self.package = package
        self.sharedRoot = sharedRoot
        for path in package?.fileList ?? [] {
            if let normalized = Self.normalize(path), packagePaths[normalized.lowercased()] == nil {
                packagePaths[normalized.lowercased()] = path
            }
        }
    }

    static func normalize(_ path: String) -> String? {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), !path.contains(":"), !path.contains("\0") else { return nil }
        let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    func report(_ kind: SceneAssetIssue.Kind, _ path: String, _ detail: String) {
        let issue = SceneAssetIssue(kind: kind, path: path, detail: detail)
        guard !issues.contains(issue) else { return }
        issues.append(issue)
        didReport?(issues)
    }

    func data(_ path: String, required: Bool = false) -> Data? {
        asset(candidates: [path], required: required)?.data
    }

    func asset(candidates: [String], required: Bool = false) -> Asset? {
        let paths = Array(NSOrderedSet(array: candidates.compactMap(Self.normalize))) as? [String] ?? []
        // Source precedence applies across ALL candidates, including file extensions.
        for path in paths {
            if let key = packagePaths[path.lowercased()], let data = package?.extractFile(named: key) {
                return Asset(path: path, data: data)
            }
        }
        for root in [wallpaperRoot, sharedRoot].compactMap({ $0 }) {
            for path in paths {
                if let url = file(path, under: root), let data = try? Data(contentsOf: url) {
                    return Asset(path: path, data: data)
                }
            }
        }
        if required {
            report(paths.isEmpty ? .invalid : .missing, candidates.first ?? "", paths.isEmpty
                ? "Invalid relative asset path" : "Searched wallpaper package, wallpaper folder and shared assets: " + paths.joined(separator: ", "))
        }
        return nil
    }

    private func file(_ path: String, under root: URL) -> URL? {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let key = root.path + "/" + path
        if let cached = diskPaths[key] { return cached }
        var url = root
        for component in path.split(separator: "/").map(String.init) {
            let exact = url.appendingPathComponent(component)
            if FileManager.default.fileExists(atPath: exact.path) { url = exact }
            else {
                guard let children = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                      let match = children.sorted().first(where: { $0.lowercased() == component.lowercased() }) else { return nil }
                url.appendPathComponent(match)
            }
        }
        url = url.resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        diskPaths[key] = url
        return url
    }
}

/// A manifest swap activates a fully copied snapshot. Failed imports leave the previous copy intact.
struct EngineAssetLibrary {
    static let didChange = Notification.Name("EngineAssetLibraryDidChange")
    static let standard = EngineAssetLibrary(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Open Wallpaper Engine/EngineAssets", isDirectory: true))
    let root: URL
    struct Manifest: Codable {
        let snapshot: String
        let importedAt: Date
        let source: String
        let fileCount: Int
    }
    var manifest: Manifest? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("active.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              UUID(uuidString: manifest.snapshot) != nil else { return nil }
        return manifest
    }
    var activeRoot: URL? {
        guard let manifest else { return nil }
        let url = root.appendingPathComponent(manifest.snapshot)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("materials").path) ? url : nil
    }

    enum ImportError: LocalizedError {
        case invalidFolder, unsafeFile
        var errorDescription: String? {
            switch self {
            case .invalidFolder: return String(localized: "Choose Wallpaper Engine’s assets folder, or its installation folder. Nonempty materials and shaders folders are required.")
            case .unsafeFile: return String(localized: "The asset folder contains a symbolic link or unsupported file. Choose an original Wallpaper Engine assets folder.")
            }
        }
    }

    func importFolder(_ selected: URL, source: String = "local") throws -> Manifest {
        let fm = FileManager.default
        let nested = selected.appendingPathComponent("assets")
        let input = fm.fileExists(atPath: nested.path) ? nested : selected
        try validate(input)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = UUID().uuidString
        let destination = root.appendingPathComponent(snapshot)
        var activated = false
        defer { if !activated { try? fm.removeItem(at: destination) } }
        try fm.copyItem(at: input, to: destination)
        let count = try validate(destination)
        let manifest = Manifest(snapshot: snapshot, importedAt: Date(), source: source, fileCount: count)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("active.json"), options: .atomic)
        activated = true
        return manifest
    }

    @discardableResult
    private func validate(_ folder: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: folder.path) else { throw ImportError.invalidFolder }
        guard (try folder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw ImportError.unsafeFile }
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard (try? folder.resourceValues(forKeys: Set(keys)).isSymbolicLink) == false,
              let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { throw ImportError.invalidFolder }
        var count = 0, categories = Set<String>()
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw ImportError.unsafeFile }
            if values.isRegularFile == true {
                count += 1
                if (values.fileSize ?? 0) > 0 {
                    let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(folder.path.count + 1))
                    if let first = relative.split(separator: "/").first { categories.insert(String(first)) }
                }
            }
        }
        guard categories.contains("materials"), categories.contains("shaders") else { throw ImportError.invalidFolder }
        return count
    }
}
