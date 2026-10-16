//
//  WEProject.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI
import ImageIO

/// Preserve all property definitions and their native JSON types during metadata edits.
indirect enum WEProjectJSONValue: Codable, Equatable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: WEProjectJSONValue]), array([WEProjectJSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: WEProjectJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([WEProjectJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
typealias WEProjectGeneral = [String: WEProjectJSONValue]

enum WorkshopId: Codable, Equatable, Hashable, RawRepresentable {
    case int(Int)
    case string(String)
    
    var rawValue: String {
        switch self {
        case .int(let x):
            return String(x)
        case .string(let x):
            return x
        }
    }
    
    init?(rawValue: String) {
        guard rawValue.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self = .string(rawValue)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(Int.self) {
            self = .int(x)
            return
        }
        if let x = try? container.decode(String.self) {
            self = .string(x)
            return
        }
        throw DecodingError.typeMismatch(Self.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for Workshop ID"))
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let x):
            try container.encode(x)
        case .string(let x):
            try container.encode(x)
        }
    }
}

struct WEProject: Codable, Equatable, Hashable {
    var approved: Bool?
    var contentrating: String?
    var description: String?
    var file: String
    var general: WEProjectGeneral?
    var preview: String
    var tags: [String]?
    var title: String
    var visibility: String?
    var workshopid: WorkshopId?
    var workshopurl: String?
    var type: String
    var version: Int?
    var dependency: WorkshopId?
    var preset: WEProjectGeneral?
    
    static let invalid = Self(file: "",
                              preview: "",
                              title: "Error",
                              type: "video")
}

extension WEProject {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dependency = try c.decodeIfPresent(WorkshopId.self, forKey: .dependency)
        preset = try c.decodeIfPresent(WEProjectGeneral.self, forKey: .preset)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? (dependency != nil ? "" : c.decode(String.self, forKey: .file))
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? (dependency != nil ? "preset" : c.decode(String.self, forKey: .type))
        title = try c.decode(String.self, forKey: .title)
        preview = try c.decode(String.self, forKey: .preview)
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved)
        contentrating = try c.decodeIfPresent(String.self, forKey: .contentrating)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        general = try c.decodeIfPresent(WEProjectGeneral.self, forKey: .general)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        workshopid = try c.decodeIfPresent(WorkshopId.self, forKey: .workshopid)
        workshopurl = try c.decodeIfPresent(String.self, forKey: .workshopurl)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
    }
}

/// Resolves presets without changing either source project's metadata or assets.
enum WEPresetResolver {
    static var downloadDependency: ((String, URL) async throws -> Void)?
    static let runtimeName = ".preset-runtime"
    private static let materializationLock = NSLock()
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func metadata(_ directory: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("project.json"))) as? [String: Any] else {
            throw Failure(message: "Invalid wallpaper project.json")
        }
        return object
    }
    static func dependency(in json: [String: Any]) throws -> String? {
        guard let value = json["dependency"] else { return nil }
        let id = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw Failure(message: "Invalid wallpaper dependency ID")
        }
        return id
    }
    static func prepare(_ wallpaper: WEWallpaper) async throws -> WEWallpaper {
        let directory = wallpaper.wallpaperDirectory
        guard wallpaper.project.dependency != nil else { return wallpaper }
        let library = directory.deletingLastPathComponent()
        var chain: [URL] = [], visited = Set<String>()
        var current = directory
        while true {
            try Task.checkCancellation()
            guard visited.insert(current.standardizedFileURL.path).inserted, chain.count < 32 else {
                throw Failure(message: "Wallpaper preset dependency cycle or excessive depth")
            }
            chain.append(current)
            guard let id = try dependency(in: metadata(current)) else { break }
            let next = library.appendingPathComponent(id)
            if !FileManager.default.fileExists(atPath: next.appendingPathComponent("project.json").path) {
                guard let downloadDependency else { throw Failure(message: "Missing original wallpaper: " + id) }
                try await downloadDependency(id, next)
            }
            current = next
        }
        let resolvedChain = chain
        let result = try await Task.detached(priority: .userInitiated) { try materialize(chain: resolvedChain) }.value
        try Task.checkCancellation()
        return WEWallpaper(using: result, where: directory)
    }
    /// Chain is ordered from selected preset to the original wallpaper.
    static func materialize(chain: [URL]) throws -> WEProject {
        materializationLock.lock()
        defer { materializationLock.unlock() }
        guard let selected = chain.first, let base = chain.last else { throw Failure(message: "Empty preset chain") }
        let fm = FileManager.default
        let staging = selected.appendingPathComponent(".preset-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var merged = try metadata(base)
        func overlay(_ source: URL, _ destination: URL) throws {
            for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: .skipsHiddenFiles) {
                if item.lastPathComponent == "project.json" { continue }
                let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true else { throw Failure(message: "Unsupported symlink in wallpaper preset") }
                let target = destination.appendingPathComponent(item.lastPathComponent)
                if values.isDirectory == true {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try overlay(item, target)
                } else {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: item, to: target)
                }
            }
        }
        for directory in chain.reversed() {
            try overlay(directory, staging)
            let json = try metadata(directory)
            if directory != base {
                var general = merged["general"] as? [String: Any] ?? [:]
                var definitions = general["properties"] as? [String: [String: Any]] ?? [:]
                for (key, value) in json["preset"] as? [String: Any] ?? [:] {
                    guard !(value is NSNull), var definition = definitions[key] else { continue }
                    definition["value"] = value
                    definitions[key] = definition
                }
                general["properties"] = definitions
                merged["general"] = general
                for key in ["title", "preview", "description", "tags", "contentrating", "workshopid", "workshopurl", "dependency", "preset"] {
                    if let value = json[key] { merged[key] = value }
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        let project = try JSONDecoder().decode(WEProject.self, from: data)
        guard !project.file.isEmpty, ["scene", "video", "web"].contains(project.type.lowercased()) else {
            throw Failure(message: "Unsupported original wallpaper type: " + project.type)
        }
        try data.write(to: staging.appendingPathComponent("project.json"))
        let destination = selected.appendingPathComponent(runtimeName)
        let backup = selected.appendingPathComponent(".preset-backup-" + UUID().uuidString)
        let exists = fm.fileExists(atPath: destination.path)
        if exists { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch { if exists { try? fm.moveItem(at: backup, to: destination) }; throw error }
        if exists { try? fm.removeItem(at: backup) }
        return project
    }
}

struct WEWallpaper: Codable, RawRepresentable, Identifiable {
    
    var id: Int { self.project.hashValue }
    var rawValue: String {
        do {
            let rawValueData = try JSONEncoder().encode(self)
            return String(data: rawValueData, encoding: .utf8)!
        } catch {
            print(error)
            return ""
        }
    }
    
    var wallpaperDirectory: URL
    var project: WEProject
    
    var wallpaperSize: Int {
        guard let sizeBytes = try? self.wallpaperDirectory.directoryTotalAllocatedSize(includingSubfolders: true)
        else { return 0 }
        return sizeBytes
    }
    
    init(using project: WEProject, where url: URL) {
        self.wallpaperDirectory = url
        self.project = project
    }
    
    enum CodingKeys: CodingKey {
        case wallpaperDirectory
        case project
        // <all the other elements too>
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.wallpaperDirectory = try container.decode(URL.self, forKey: .wallpaperDirectory)
        self.project = try container.decode(WEProject.self, forKey: .project)
        // <and so on>
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallpaperDirectory, forKey: .wallpaperDirectory)
        try container.encode(project, forKey: .project)
        // <and so on>
    }
    
    init?(rawValue: String) {
        if let rawValueData = rawValue.data(using: .utf8),
           let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: rawValueData) {
            self = wallpaper
        } else {
            return nil
        }
    }
}

enum WEWallpaperSortingMethod: String, CaseIterable, Identifiable {
    
    var id: Self { self }
    
    case name = "Name"
    case rating = "Rating"
//    case favorite = "Favorite"
    case fileSize = "File Size"
//    case subDate = "Subscription Date"
//    case lastUpdated = "Last Updated"
}

enum WEWallpaperSortingSequence: Int {
    case decrease = 0, increase = 1
}

enum WEInitError: Error {
    enum WEJSONProjectInitError: Error {
        case notFound, corrupted, mismatched, unkownError
    }
    
    enum WEResourcesInitError: Error {
        case notFound, mismatchedFormat, corrupted, unkownError
    }
    
    enum WEPreviewInitError: Error {
        case notFound, notImage, unkownError
    }
    
    case badDirectoryPath
    case JSONProject(was: WEJSONProjectInitError)
    case resources(was: WEResourcesInitError)
    case preview(was: WEPreviewInitError)
}
