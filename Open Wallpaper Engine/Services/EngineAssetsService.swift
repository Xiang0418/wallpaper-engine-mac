import Foundation
import Combine

/// Steam reports progress per installation phase, not individual filenames.
struct EngineAssetProgress: Equatable {
    enum Phase { case connecting, allocating, downloading, validating, committing, importing }
    let phase: Phase
    var fraction: Double? = nil
    var completedBytes: Int64? = nil
    var totalBytes: Int64? = nil
    var depotFileCount: Int? = nil
    var depotSizeMB: Int? = nil
    var title: String {
        switch phase {
        case .connecting: return String(localized: "Connecting to Steam…")
        case .allocating: return String(localized: "Preparing disk space…")
        case .downloading: return String(localized: "Downloading Wallpaper Engine content…")
        case .validating: return String(localized: "Validating downloaded content…")
        case .committing: return String(localized: "Installing downloaded content…")
        case .importing: return String(localized: "Copying and validating shared assets…")
        }
    }
    var content: String {
        phase == .importing ? String(localized: "Shared scene assets")
            : String(localized: "Wallpaper Engine · Original content (depot 431961)")
    }
    var byteSummary: String? {
        guard let completedBytes, let totalBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
            + " / " + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

struct EngineAssetProgressParser {
    private var pending = ""
    mutating func consume(_ chunk: String) -> [EngineAssetProgress] {
        pending += chunk
        var updates: [EngineAssetProgress] = []
        while let end = pending.firstIndex(where: { $0.isNewline }) {
            let line = String(pending[..<end])
            pending.removeSubrange(...end)
            if let update = Self.parse(line) { updates.append(update) }
        }
        // Steam output can contain noisy or unterminated lines. Bound memory without displaying raw output.
        if pending.utf8.count > 16384 { pending = String(pending.suffix(8192)) }
        return updates
    }

    static func parse(_ line: String) -> EngineAssetProgress? {
        let lower = line.lowercased()
        let phase: EngineAssetProgress.Phase
        if lower.contains("update state") {
            if lower.contains("downloading") { phase = .downloading }
            else if lower.contains("validating") || lower.contains("verifying") { phase = .validating }
            else if lower.contains("preallocating") || lower.contains("allocating") { phase = .allocating }
            else if lower.contains("committing") { phase = .committing }
            else { return nil }
        } else if lower.contains("downloading depot") || lower.contains("download depot version") {
            var result = EngineAssetProgress(phase: .downloading)
            if let regex = try? NSRegularExpression(pattern: #"\(([0-9]+) files, ([0-9]+) MB\)"#),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let count = Range(match.range(at: 1), in: line), let size = Range(match.range(at: 2), in: line) {
                result.depotFileCount = Int(line[count]); result.depotSizeMB = Int(line[size])
            }
            return result
        } else if lower.contains("logging in") || lower.contains("connecting") || lower.contains("waiting for user info") || lower.contains("waiting for client config") {
            return EngineAssetProgress(phase: .connecting)
        } else { return nil }
        var result = EngineAssetProgress(phase: phase)
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
        }
        if let raw = groups(#"progress:\s*([0-9]+(?:\.[0-9]+)?)(?=\s|%|$)"#)?.first,
           let value = Double(raw), value.isFinite, (0...100).contains(value) { result.fraction = value / 100 }
        if let bytes = groups(#"\(\s*([0-9]+)\s*/\s*([0-9]+)\s*\)"#), bytes.count == 2,
           let done = Int64(bytes[0]), let total = Int64(bytes[1]), total > 0, done <= total {
            result.completedBytes = done; result.totalBytes = total
            if result.fraction == nil { result.fraction = Double(done) / Double(total) }
        }
        return result
    }
}

@MainActor
final class EngineAssetsService: ObservableObject {
    static let shared = EngineAssetsService()
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    @Published private(set) var progress: EngineAssetProgress?
    private var operationID = UUID()
    private var lastProgressSequence = -1
    @Published private(set) var error: String?
    @Published private(set) var manifest: EngineAssetLibrary.Manifest?
    let library: EngineAssetLibrary

    init(library: EngineAssetLibrary = .standard) {
        self.library = library
        manifest = library.activeRoot == nil ? nil : library.manifest
    }

    func importFolder(_ url: URL) {
        guard !isBusy else { return }
        begin(.importing)
        let library = library
        Task { [self] in
            let result = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try library.importFolder(url) }
            }.value
            finish(result)
        }
    }

    nonisolated static func downloadArguments(username: String, destination: URL) -> [String] {
        ["+@sSteamCmdForcePlatformType", "windows", "+force_install_dir", destination.path,
         "+@NoPromptForPassword", "1", "+login", username,
         "+download_depot", "431960", "431961", "+quit"]
    }

    func download(using steam: SteamCmdService) {
        guard !isBusy, !steam.isLoggingIn, !steam.hasActiveWorkshopDownloads,
              !steam.isDownloadingEngineAssets, steam.isLoggedIn, let executable = steam.steamCmdPath else { return }
        begin(.connecting)
        let operation = operationID
        steam.isDownloadingEngineAssets = true
        let username = steam.steamUsername, library = library
        // Download only the official content depot. app_update also schedules subscribed Workshop items.
        let destination = library.root.appendingPathComponent("steam-install", isDirectory: true)
        Task { [self] in
            let result: Result<EngineAssetLibrary.Manifest, Error> = await Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    var parser = EngineAssetProgressParser()
                    var sequence = 0
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    let result = try SteamDownloadProcess.run(executable: URL(fileURLWithPath: executable),
                        arguments: Self.downloadArguments(username: username, destination: destination),
                        workshopID: "", appID: "431960", depotID: "431961") { chunk in
                            for update in parser.consume(chunk) {
                                sequence += 1
                                let currentSequence = sequence
                                Task { @MainActor [weak self] in
                                    self?.apply(update, operation: operation, sequence: currentSequence)
                                }
                            }
                        }
                    guard result.succeeded, let depotDirectory = result.depotDirectory else {
                        throw DownloadError.failed(Self.failureMessage(output: result.output, timedOut: result.timedOut, exitCode: result.exitCode))
                    }
                    await self?.apply(EngineAssetProgress(phase: .importing), operation: operation, sequence: Int.max)
                    return .success(try library.importFolder(depotDirectory, source: "steam"))
                } catch { return .failure(error) }
            }.value
            steam.isDownloadingEngineAssets = false
            finish(result)
        }
    }

    private func begin(_ phase: EngineAssetProgress.Phase) {
        operationID = UUID(); lastProgressSequence = -1
        isBusy = true; error = nil
        progress = EngineAssetProgress(phase: phase); status = progress!.title
    }

    private func apply(_ update: EngineAssetProgress, operation: UUID, sequence: Int) {
        guard isBusy, operationID == operation, sequence > lastProgressSequence else { return }
        lastProgressSequence = sequence
        progress = update; status = update.title
    }

    nonisolated static func failureMessage(output: String, timedOut: Bool, exitCode: Int32?) -> String {
        let lower = output.lowercased()
        if lower.contains("invalid password") || lower.contains("no cached credentials") || lower.contains("account logon denied") {
            return String(localized: "SteamCMD’s saved login has expired. Sign in again in the Workshop tab; browser login is separate.")
        }
        if lower.contains("steam guard code") || lower.contains("two-factor code") {
            return String(localized: "SteamCMD requires a Steam Guard code. Complete sign-in in the Workshop tab.")
        }
        if lower.contains("no subscription") || lower.contains("missing license") {
            return String(localized: "Steam reports that this account does not have a license for Wallpaper Engine.")
        }
        if lower.contains("disk write failure") || lower.contains("not enough disk space") {
            return String(localized: "Steam could not write the download. Check available disk space and folder permissions.")
        }
        if lower.contains("missing update files") || lower.contains("state is 0x204") {
            return String(localized: "Steam reported missing update files. This is a content update failure, not a login failure. Existing shared assets are preserved.")
        }
        if timedOut { return String(localized: "Steam stopped responding. Retry the download; your current assets are unchanged.") }
        return String(localized: "Steam did not confirm that the content depot finished downloading. Your existing assets are unchanged. Exit code:")
            + " " + (exitCode.map(String.init) ?? "—")
    }

    private enum DownloadError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }

    private func finish(_ result: Result<EngineAssetLibrary.Manifest, Error>) {
        isBusy = false; status = ""; progress = nil
        switch result {
        case .success(let manifest):
            self.manifest = manifest
            NotificationCenter.default.post(name: EngineAssetLibrary.didChange, object: nil)
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}
