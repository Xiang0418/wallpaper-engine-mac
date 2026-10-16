import Foundation
import Darwin

/// One owner drains the pipe and observes process state. No blocking EOF read is
/// allowed after a timeout: a stuck Steam child may still hold the pipe open.
enum SteamDownloadProcess {
    static func recordDuration(_ phase: String, id: String, since started: TimeInterval) {
        NSLog("[WorkshopPerformance] item=%@ phase=%@ seconds=%.3f", id, phase,
              ProcessInfo.processInfo.systemUptime - started)
    }

    /// Use only newly appended native logs; stdout is buffered and cannot mark
    /// the start of a network transfer reliably.
    struct NativeTimings {
        var phases: [String: TimeInterval] = [:]
        var outcome: String?

        static func parse(workshop: String, content: String, id: String, launched: Date) -> NativeTimings {
            var result = NativeTimings()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            func timestamp(_ line: String) -> Date? {
                guard line.hasPrefix("["), line.count >= 21 else { return nil }
                return formatter.date(from: String(line.dropFirst().prefix(19)))
            }
            let lines = workshop.components(separatedBy: .newlines).filter { $0.contains("[AppID 431960]") }
            guard let request = lines.first(where: { $0.contains("Download item " + id + " requested by app") }),
                  let start = timestamp(request),
                  let completion = lines.first(where: { $0.contains("Download item " + id + " result :") }),
                  let end = timestamp(completion), end >= start else { return result }
            result.phases["native.job"] = end.timeIntervalSince(start)
            result.phases["native.startup_and_login"] = max(0, start.timeIntervalSince(launched))
            result.outcome = completion.hasSuffix("result : OK") ? "ok" : "failed"
            guard let manifestLine = lines.first(where: { $0.contains("item " + id + ", new manifest ") }),
                  let manifest = manifestLine.components(separatedBy: "new manifest ").last,
                  !manifest.isEmpty, manifest.allSatisfy(\.isNumber) else { return result }
            let contentLines = content.components(separatedBy: .newlines)
            guard let index = contentLines.firstIndex(where: { $0.contains("chunks for depot 431960 (" + manifest + ")") }),
                  let transfer = timestamp(contentLines[index]), transfer >= start, transfer <= end else { return result }
            var commit: Date?
            for line in contentLines.dropFirst(index + 1) {
                guard let date = timestamp(line), date <= end else { continue }
                // Another writer sharing this log makes untagged commit events ambiguous.
                if line.contains("chunks for depot 431960 (") { return result }
                if line.contains("AppID 431960 starting commit") { commit = date; break }
            }
            result.phases["native.request_to_transfer"] = transfer.timeIntervalSince(start)
            if let commit, commit >= transfer {
                result.phases["native.transfer_and_staging"] = commit.timeIntervalSince(transfer)
                result.phases["native.commit_and_validation"] = end.timeIntervalSince(commit)
            }
            return result
        }
    }

    private struct LogSlice {
        let url: URL
        let offset: UInt64
        let inode: UInt64?
        init(_ url: URL) {
            self.url = url
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            offset = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        func appended() -> String {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  size >= offset, size - offset <= 8 * 1024 * 1024,
                  inode == nil || inode == (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: offset)
                return String(decoding: try handle.read(upToCount: Int(size - offset)) ?? Data(), as: UTF8.self)
            } catch { return "" }
        }
    }

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
        try SteamDownloadQueue.sync(id: workshopID) {
            try runIsolated(executable: executable, arguments: arguments, workshopID: workshopID,
                idleTimeout: idleTimeout, terminationGrace: terminationGrace, appID: appID, depotID: depotID, progress: progress)
        }
    }

    private static func runIsolated(executable: URL, arguments: [String], workshopID: String,
                    idleTimeout: TimeInterval, terminationGrace: TimeInterval,
                    appID: String?, depotID: String?, progress: (String) -> Void) throws -> Result {
        let totalStarted = ProcessInfo.processInfo.systemUptime
        let launched = Date()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [executable.deletingLastPathComponent().appendingPathComponent("logs"),
                     home.appendingPathComponent("Library/Application Support/Steam/logs"),
                     home.appendingPathComponent("Steam/logs")]
        let slices = workshopID.isEmpty ? [] : roots.map {
            (LogSlice($0.appendingPathComponent("workshop_log.txt")), LogSlice($0.appendingPathComponent("content_log.txt")))
        }
        defer {
            recordDuration("steamcmd.total", id: workshopID, since: totalStarted)
            var found = false
            for (workshop, content) in slices {
                let native = NativeTimings.parse(workshop: workshop.appended(), content: content.appended(), id: workshopID, launched: launched)
                guard let outcome = native.outcome else { continue }
                for (phase, seconds) in native.phases.sorted(by: { $0.key < $1.key }) {
                    NSLog("[WorkshopPerformance] item=%@ phase=%@ seconds=%.3f source=native resolution=1s", workshopID, phase, seconds)
                }
                NSLog("[WorkshopPerformance] item=%@ native.result=%@", workshopID, outcome)
                found = true; break
            }
            if !workshopID.isEmpty && !found { NSLog("[WorkshopPerformance] item=%@ native.timing=unavailable", workshopID) }
        }
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
                let text = String(decoding: buffer.prefix(count), as: UTF8.self)
                progress(text)
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

/// One FIFO owns SteamCMD writes, including dependencies and engine assets.
/// A job may import its result on this queue, but must release it before awaiting
/// dependencies. Reentrant sync permits callers already on the worker to run.
enum SteamDownloadQueue {
    private static let key = DispatchSpecificKey<Bool>()
    static let worker: DispatchQueue = {
        let queue = DispatchQueue(label: "wallpaper.steam-downloads", qos: .userInitiated)
        queue.setSpecific(key: key, value: true)
        return queue
    }()

    static func sync<T>(id: String, _ operation: () throws -> T) rethrows -> T {
        _ = worker
        if DispatchQueue.getSpecific(key: key) == true { return try operation() }
        let queued = ProcessInfo.processInfo.systemUptime
        return try worker.sync {
            SteamDownloadProcess.recordDuration("queue", id: id, since: queued)
            return try operation()
        }
    }

    static func perform<T>(id: String, _ operation: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let queued = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation { continuation in
            worker.async {
                SteamDownloadProcess.recordDuration("queue", id: id, since: queued)
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}
