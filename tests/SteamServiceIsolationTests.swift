import Foundation
import Combine

extension FileManager {
    var wallpapersDirectory: URL { temporaryDirectory.appendingPathComponent("unused-workshop-test-library") }
}

@main struct SteamServiceIsolationTests {
    @MainActor static func main() throws {
        let suite = "SteamServiceIsolationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<100 {
            let service = SteamCmdService(startAutomatically: false, defaults: defaults) { path, arguments, _ in
                precondition(!Thread.isMainThread)
                precondition(path == "/test/steamcmd")
                precondition(arguments == ["+login", "test-only", "+quit"])
                Thread.sleep(forTimeInterval: 0.002)
                return ("Invalid Password", 1)
            }
            service.steamCmdPath = "/test/steamcmd"
            service.loginWithCachedSession(username: "test-only")
            // Reproduce first Workshop entry: observe and read while login runs.
            var notifications = 0
            let subscription = service.objectWillChange.sink {
                precondition(Thread.isMainThread)
                notifications += 1
            }
            service.steamCmdPath = nil
            let suite = "SteamServiceIsolationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<100 {
                precondition(!service.isInstalled)
                _ = service.steamUsername
            }
            for _ in 0..<2000 where service.isLoggingIn {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            precondition(!service.isLoggingIn, "Background login must finish")
            precondition(service.loginError == "Cached session expired. Please log in with password.")
            precondition(notifications > 1)
            withExtendedLifetime(subscription) {}
        }
        print("PASS: 100 first-entry observation/login cycles, main-thread notifications, path snapshot survives state change")
    }
}
