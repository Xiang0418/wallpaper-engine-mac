import Foundation
import Combine

extension FileManager {
    var wallpapersDirectory: URL { temporaryDirectory.appendingPathComponent("unused-assets-test-wallpapers") }
}

@main struct EngineAssetsServiceTests {
    @MainActor static func main() throws {
        let missing = EngineAssetsService.failureMessage(output: "Error! App '431960' state is 0x204 after update job.", timedOut: false, exitCode: 1)
        precondition(missing.contains("content update failure"))
        let expired = EngineAssetsService.failureMessage(output: "FAILED (No cached credentials and @NoPromptForPassword is set)", timedOut: false, exitCode: 1)
        precondition(expired.contains("saved login has expired"))
        let unknown = EngineAssetsService.failureMessage(output: "unexpected end", timedOut: false, exitCode: 0)
        precondition(!unknown.contains("Steam Guard") && unknown.contains("did not confirm"))
        let header = EngineAssetProgressParser.parse("Downloading depot 431961 (6301 files, 359 MB) ...")
        precondition(header?.depotFileCount == 6301 && header?.depotSizeMB == 359 && header?.fraction == nil)
        var parser = EngineAssetProgressParser()
        precondition(parser.consume("Update state (0x61) downloading, pro").isEmpty)
        let parsed = parser.consume("gress: 42.50 (425 / 1000)\rUpdate state (0x5) validating, progress: 3.0 (30 / 1000)\r\n")
        precondition(parsed.count == 2 && parsed[0].phase == .downloading && parsed[0].fraction == 0.425)
        precondition(parsed[0].completedBytes == 425 && parsed[0].totalBytes == 1000)
        precondition(parsed[1].phase == .validating && parsed[1].fraction == 0.03)
        precondition(parser.consume("account secret session output\n").isEmpty)
        precondition(EngineAssetProgressParser.parse("Update state (0x61) downloading, progress: nan")?.fraction == nil)
        precondition(EngineAssetProgressParser.parse("Update state (0x61) downloading, progress: 150")?.fraction == nil)
        precondition(EngineAssetProgressParser.parse("Update state (0x61) downloading, progress: 1.2.3")?.fraction == nil)
        precondition(EngineAssetProgressParser.parse("Update state (0x61) downloading, (1 / 0)")?.totalBytes == nil)
        precondition(EngineAssetProgressParser.parse("Update state (0x61) downloading, (25 / 100)")?.fraction == 0.25)
        precondition(EngineAssetProgressParser.parse("Update state (0x101) committing")?.fraction == nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("engine-service-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-steamcmd")
        let script = """
        #!/bin/sh
        [ "$1" = '+@sSteamCmdForcePlatformType' ] && [ "$2" = windows ] || exit 10
        [ "$3" = '+force_install_dir' ] || exit 11
        destination="$4"
        [ "$5" = '+@NoPromptForPassword' ] && [ "$6" = 1 ] || exit 12
        [ "$7" = '+login' ] && [ "$8" = fixture-user ] || exit 13
        shift 8
        [ "$1" = '+download_depot' ] && [ "$2" = 431960 ] && [ "$3" = 431961 ] || exit 14
        destination="$destination/steamapps/content/app_431960/depot_431961"
        mkdir -p "$destination/assets/materials" "$destination/assets/shaders"
        printf '{}' > "$destination/assets/materials/shared.json"
        printf 'shader' > "$destination/assets/shaders/shared.frag"
        printf 'Update state (0x61) downloading, pro'
        sleep 0.05
        printf 'gress: 42.50 (425 / 1000)\\r'
        sleep 0.05
        printf 'Update state (0x5) validating, progress: 3.0 (30 / 1000)\\n'
        sleep 0.05
        printf 'Depot download complete : "%s" (manifest 12345)\\n' "$destination"
        """
        try Data(script.utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let suite = "EngineAssetsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let steam = SteamCmdService(startAutomatically: false, defaults: defaults)
        steam.steamCmdPath = executable.path; steam.steamUsername = "fixture-user"; steam.isLoggedIn = true
        let assets = EngineAssetsService(library: EngineAssetLibrary(root: root.appendingPathComponent("library with spaces")))
        var observed: [EngineAssetProgress] = []
        let subscription = assets.$progress.compactMap { $0 }.sink { observed.append($0) }
        defer { subscription.cancel() }
        func wait() {
            let deadline = Date().addingTimeInterval(15)
            while assets.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(!assets.isBusy, "Operation must finish")
        }
        steam.downloadProgress["test"] = .downloading(status: "active")
        assets.download(using: steam)
        precondition(!assets.isBusy, "Must not race Workshop downloads")
        steam.downloadProgress.removeAll()
        assets.download(using: steam)
        precondition(assets.isBusy && steam.isDownloadingEngineAssets)
        steam.downloadWorkshopItem(workshopId: "blocked")
        precondition(steam.downloadProgress["blocked"] == nil)
        wait()
        precondition(assets.error == nil && assets.manifest?.source == "steam" && !steam.isDownloadingEngineAssets)
        precondition(observed.contains { $0.phase == .downloading && $0.fraction == 0.425 })
        precondition(observed.contains { $0.phase == .validating && $0.fraction == 0.03 })
        precondition(observed.last?.phase == .importing && assets.progress == nil, "Import clears download percent; completion clears progress")
        let previous = assets.manifest?.snapshot
        try Data("#!/bin/sh\necho ERROR\nexit 0\n".utf8).write(to: executable)
        assets.download(using: steam); wait()
        precondition(assets.error != nil && assets.manifest?.snapshot == previous, "Stale installation cannot turn a failed download into success")
        assets.importFolder(root.appendingPathComponent("missing")); wait()
        precondition(assets.error != nil && assets.manifest?.snapshot == previous)
        print("Engine asset service: Steam arguments, download activation, concurrency guards, retry and failure preservation passed")
    }
}
