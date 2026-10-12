import Foundation
import Combine

extension FileManager {
    var wallpapersDirectory: URL { temporaryDirectory.appendingPathComponent("unused-session-test-library") }
}

@main struct SteamSessionPersistenceTests {
    @MainActor static func waitForLogin(_ service: SteamCmdService) {
        let deadline = Date().addingTimeInterval(5)
        while service.isLoggingIn && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(!service.isLoggingIn, "Login did not finish")
    }

    @MainActor static func main() throws {
        let suite = "SteamSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let executable = folder.appendingPathComponent("steamcmd")
        // A fresh login accepts a password; restoration must use only the saved username.
        try Data("""
        #!/bin/sh
        if [ "$1" != '+login' ] || [ "$2" != 'test-account' ]; then exit 1; fi
        if [ "$3" != 'test-password' ] && [ "$3" != '+quit' ]; then exit 1; fi
        echo 'Logged in OK'
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let first = SteamCmdService(startAutomatically: false, defaults: defaults)
        first.setCustomPath(executable.path)
        precondition(!first.isLoggingIn, "No saved account should mean no automatic login")
        first.login(username: "test-account", password: "test-password")
        waitForLogin(first)
        precondition(first.isLoggedIn)
        precondition(defaults.string(forKey: "SteamLastUsername") == "test-account")

        let restarted = SteamCmdService(defaults: defaults)
        precondition(restarted.isLoggingIn)
        waitForLogin(restarted)
        precondition(restarted.isLoggedIn && restarted.steamUsername == "test-account")

        let lateDetection = SteamCmdService(startAutomatically: false, defaults: defaults)
        lateDetection.steamCmdPath = executable.path
        precondition(lateDetection.isLoggingIn)
        waitForLogin(lateDetection)
        precondition(lateDetection.isLoggedIn)

        let manualPath = SteamCmdService(startAutomatically: false, defaults: defaults)
        manualPath.setCustomPath(executable.path)
        precondition(manualPath.isLoggingIn)
        waitForLogin(manualPath)
        precondition(manualPath.isLoggedIn)

        try Data("#!/bin/sh\necho 'Invalid Password'\nexit 1\n".utf8).write(to: executable)
        let expired = SteamCmdService(defaults: defaults)
        waitForLogin(expired)
        precondition(!expired.isLoggedIn && expired.loginError != nil)
        precondition(expired.steamUsername == "test-account")
        print("PASS: account persistence, restart, delayed detection, manual path, expired session")
    }
}
