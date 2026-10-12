import Foundation
import Darwin

/// One owner drains the pipe and observes process state. No blocking EOF read is
/// allowed after a timeout: a stuck Steam child may still hold the pipe open.
enum SteamDownloadProcess {
    struct Result {
        let output: String
        let downloaded: Bool
        let timedOut: Bool
        let exitCode: Int32?
        var depotDirectory: URL? = nil
        var succeeded: Bool { !timedOut && downloaded && exitCode != nil }
    }

    static func run(executable: URL, arguments: [String], workshopID: String,
                    idleTimeout: TimeInterval = 180, terminationGrace: TimeInterval = 5,
                    appID: String? = nil, depotID: String? = nil,
                    progress: (String) -> Void = { _ in }) throws -> Result {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        let reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { try? reader.close(); try? pipe.fileHandleForWriting.close() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        var output = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        var lastOutput = ProcessInfo.processInfo.systemUptime
        var terminateAt: TimeInterval?, killedAt: TimeInterval?
        var downloaded = false, timedOut = false, exitSeen = false
        var depotDirectory: URL?
        let pattern: String
        if let appID, let depotID {
            pattern = #"Depot download complete\s*:\s*"([^"\r\n]+[/\\]app_"#
                + NSRegularExpression.escapedPattern(for: appID) + #"[/\\]depot_"#
                + NSRegularExpression.escapedPattern(for: depotID) + #")"\s*\(manifest\s+[0-9]+\)"#
        } else if let appID {
            pattern = "Success!\\s*App '" + NSRegularExpression.escapedPattern(for: appID) + "' (?:fully installed|already up to date)\\."
        } else {
            pattern = "Success\\.\\s+Downloaded item\\s+" + NSRegularExpression.escapedPattern(for: workshopID) + "\\s"
        }
        let success = try NSRegularExpression(pattern: pattern)
        while true {
            // Bound a single drain so a noisy process cannot starve deadline checks.
            for _ in 0..<64 {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                lastOutput = ProcessInfo.processInfo.systemUptime
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 1024 * 1024 { output.removeFirst(output.count - 1024 * 1024) }
                let tail = String(decoding: output.suffix(65536), as: UTF8.self)
                if let match = success.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) {
                    downloaded = true
                    if depotID != nil, let range = Range(match.range(at: 1), in: tail) {
                        depotDirectory = URL(fileURLWithPath: String(tail[range]).replacingOccurrences(of: "\\", with: "/"))
                    }
                }
                progress(String(decoding: buffer.prefix(count), as: UTF8.self))
            }
            let now = ProcessInfo.processInfo.systemUptime
            if !process.isRunning {
                if exitSeen { break }
                exitSeen = true
                continue // drain output written between the last read and process exit
            }
            if terminateAt == nil, downloaded || now - lastOutput >= idleTimeout {
                timedOut = !downloaded
                terminateAt = now
                process.terminate()
            }
            if let terminateAt, now - terminateAt >= terminationGrace, killedAt == nil {
                kill(process.processIdentifier, SIGKILL)
                killedAt = now
            }
            if let killedAt, now - killedAt >= terminationGrace { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return Result(output: String(decoding: output, as: UTF8.self), downloaded: downloaded,
                      timedOut: timedOut, exitCode: process.isRunning ? nil : process.terminationStatus, depotDirectory: depotDirectory)
    }
}
