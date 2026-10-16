import Foundation

@main struct SteamDownloadTests {
    static func main() throws {
        func run(_ script: String, idle: Double = 0.2) throws -> SteamDownloadProcess.Result {
            try SteamDownloadProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                workshopID: "123", idleTimeout: idle, terminationGrace: 0.1)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let launch = formatter.date(from: "2026-10-16 01:35:06")!
        let workshop = """
        [2026-10-16 01:35:08] [AppID 431960] Download item 123 requested by app
        [2026-10-16 01:35:09] [AppID 431960] Detected workshop change : changed cached item 123, new manifest 456
        [2026-10-16 01:35:18] [AppID 431960] Download item 123 result : OK
        """
        let content = """
        [2026-10-16 01:35:10] Downloading 102 chunks for depot 431960 (456)
        [2026-10-16 01:35:17] AppID 431960 starting commit from test to test
        """
        let native = SteamDownloadProcess.NativeTimings.parse(workshop: workshop, content: content, id: "123", launched: launch)
        precondition(native.phases["native.startup_and_login"] == 2)
        precondition(native.phases["native.request_to_transfer"] == 2)
        precondition(native.phases["native.transfer_and_staging"] == 7)
        precondition(native.phases["native.commit_and_validation"] == 1)
        precondition(native.phases["native.job"] == 10 && native.outcome == "ok")
        let other = SteamDownloadProcess.NativeTimings.parse(workshop: workshop, content: content, id: "12", launched: launch)
        precondition(other.phases.isEmpty, "Never attribute another item's events")
        let ambiguous = content.replacingOccurrences(of: "[2026-10-16 01:35:17]", with:
            "[2026-10-16 01:35:15] Downloading 50 chunks for depot 431960 (789)\n[2026-10-16 01:35:17]")
        let concurrent = SteamDownloadProcess.NativeTimings.parse(workshop: workshop, content: ambiguous, id: "123", launched: launch)
        precondition(concurrent.phases["native.transfer_and_staging"] == nil)
        let failed = SteamDownloadProcess.NativeTimings.parse(workshop: workshop.replacingOccurrences(of: "result : OK", with: "result : Failure"), content: "", id: "123", launched: launch)
        precondition(failed.outcome == "failed" && failed.phases["native.job"] == 10)
        // Real subprocesses would collide on this directory if serialization failed.
        let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("steam-queue-" + UUID().uuidString).path
        let group = DispatchGroup()
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var successes = 0
            func record(_ success: Bool) { lock.lock(); defer { lock.unlock() }; if success { successes += 1 } }
        }
        let results = Results()
        for _ in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let script = "mkdir \"$1\" || exit 9; sleep 0.1; rmdir \"$1\"; printf 'Success. Downloaded item 123 (10 bytes)\\n'"
                let outcome = try? SteamDownloadProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script, "test", lockPath], workshopID: "123", idleTimeout: 2)
                results.record(outcome?.succeeded == true)
            }
        }
        precondition(group.wait(timeout: .now() + 10) == .success && results.successes == 3,
                     "All downloads must run without overlapping their shared staging directory")
        let split = try run("printf 'Success. Down'; sleep 0.05; printf 'loaded item 123 (10 bytes)\\n'; while :; do :; done")
        precondition(split.succeeded, "Split success output terminates hung teardown")
        let slow = try run("for i in 1 2 3 4 5; do echo progress; sleep 0.07; done; printf 'Success. Downloaded item 123 (10 bytes)\\n'")
        precondition(slow.succeeded, "Active downloads exceed total idle timeout safely")
        let began = Date()
        let idle = try run("trap '' TERM; while :; do :; done")
        precondition(idle.timedOut && !idle.succeeded && Date().timeIntervalSince(began) < 2, "Unresponsive process is killed within bounded grace")
        let wrong = try run("echo 'Success. Downloaded item 1234 (10 bytes)'")
        precondition(!wrong.succeeded, "Other item IDs cannot signal success")
        let inheritedPipe = try run("(sleep 1) & printf 'Success. Downloaded item 123 (10 bytes)\\n'")
        precondition(inheritedPipe.succeeded, "Inherited pipe does not require blocking EOF read")
        let error = try run("echo ERROR; exit 0")
        precondition(!error.succeeded, "Exit zero alone cannot validate stale download folders")
        func app(_ script: String) throws -> SteamDownloadProcess.Result {
            try SteamDownloadProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                workshopID: "", idleTimeout: 0.2, terminationGrace: 0.1, appID: "431960")
        }
        let installed = try app("printf \"Success! App '431960' fully installed.\\n\"")
        precondition(installed.succeeded)
        let different = try app("printf \"Success! App '4319600' fully installed.\\n\"")
        precondition(!different.succeeded)
        let stale = try app("echo 'already have files'; exit 0")
        precondition(!stale.succeeded, "App download requires its own success marker")
        let depot = try SteamDownloadProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' 'Depot download complete : \"/tmp/with spaces\\app_431960\\depot_431961\" (manifest 12345)'"] ,
            workshopID: "", idleTimeout: 0.2, terminationGrace: 0.1, appID: "431960", depotID: "431961")
        precondition(depot.succeeded && depot.depotDirectory?.path == "/tmp/with spaces/app_431960/depot_431961")
        let wrongDepot = try SteamDownloadProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' 'Depot download complete : \"/tmp/app_431960/depot_431960\" (manifest 12345)'"] ,
            workshopID: "", idleTimeout: 0.2, terminationGrace: 0.1, appID: "431960", depotID: "431961")
        precondition(!wrongDepot.succeeded)
        let upToDate = try app("printf \"Success!App '431960' already up to date.\\n\"")
        precondition(upToDate.succeeded)
        print("Download split output, idle timeout, forced termination and completion validation: passed")
    }
}
