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
        print("Download split output, idle timeout, forced termination and completion validation: passed")
    }
}
