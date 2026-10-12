import Foundation

@main struct SteamDownloadTests {
    static func main() throws {
        func run(_ script: String, idle: Double = 0.2) throws -> SteamDownloadProcess.Result {
            try SteamDownloadProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                workshopID: "123", idleTimeout: idle, terminationGrace: 0.1)
        }
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
