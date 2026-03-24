import Foundation

// MARK: - AI Session Detection for Terminal Panels
//
// Detects running AI coding agents (Claude Code, Codex, etc.) in terminal panels
// by inspecting child processes of the shell via the PTY name. Captures session
// identifiers so that sessions can be automatically resumed after a crash or restart.
//
// Session ID Resolution Strategy (Claude Code):
// 1. Find the claude PID running on the terminal's TTY
// 2. Get the PID's CWD via `lsof -d cwd` and start time via `ps -o lstart=`
// 3. Encode CWD to Claude's project directory format (~/.claude/projects/-path-encoded)
// 4. Scan all .jsonl files in that project dir that were modified after PID start
// 5. For each file, find the first entry timestamped >= PID start time
// 6. Score: prefer sessions created BY this PID (first entry at line 0-4, small delta)
//    over sessions that were already running (mid-file match = different PID was writing)
// 7. Lowest score wins — this disambiguates multiple sessions in the same project dir

/// Snapshot of a detected AI agent session, persisted alongside the panel snapshot.
struct AISessionSnapshot: Codable, Sendable, Equatable {
    /// The type of agent that was running.
    var agentType: AIAgentType

    /// The session/conversation identifier, if detectable.
    /// For Claude Code this is the UUID from the .jsonl filename.
    var sessionId: String?

    /// The working directory the agent was operating in.
    var workingDirectory: String?

    /// The full command that was running (e.g. "claude --dangerously-skip-permissions").
    var command: String?

    /// The project path the agent was working in (for Claude Code).
    var projectPath: String?

    /// Timestamp when the session was last detected as active.
    var lastSeenActive: TimeInterval

    /// Builds the shell command to resume this session.
    var resumeCommand: String? {
        switch agentType {
        case .claudeCode:
            if let sessionId {
                return "claude --resume \(sessionId)"
            }
            return "claude --resume"
        case .codex:
            // Codex doesn't expose a resumable session ID; restart it in the same directory.
            return shellCommandPrefixedWithWorkingDirectory(
                "codex",
                directory: workingDirectory ?? projectPath
            )
        }
    }
}

private func shellCommandPrefixedWithWorkingDirectory(_ command: String, directory: String?) -> String {
    guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
          !directory.isEmpty else {
        return command
    }
    return "cd \(shellSingleQuoted(directory)) && \(command)"
}

private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

/// Detects AI coding agents running inside terminal sessions.
enum AISessionDetector {

    // MARK: - Process Detection

    /// Detect an AI agent running under the given TTY.
    /// Returns nil if no known agent is found.
    static func detect(ttyName: String?, workingDirectory: String?) -> AISessionSnapshot? {
        guard let ttyName, !ttyName.isEmpty else { return nil }

        let processes = childProcesses(forTTY: ttyName)

        for proc in processes {
            if let snapshot = matchAgent(proc: proc, workingDirectory: workingDirectory) {
                return snapshot
            }
        }

        return nil
    }

    /// Detect an AI agent by scanning the process table for a given PID's children.
    /// This is a fallback when ttyName is unavailable.
    static func detect(parentPID: pid_t, workingDirectory: String?) -> AISessionSnapshot? {
        let processes = childProcesses(forParentPID: parentPID)

        for proc in processes {
            if let snapshot = matchAgent(proc: proc, workingDirectory: workingDirectory) {
                return snapshot
            }
        }

        return nil
    }

    // MARK: - Agent Matching

    struct ProcessInfo {
        let pid: pid_t
        let command: String
        let args: [String]
        let fullCommand: String
    }

    private static func matchAgent(proc: ProcessInfo, workingDirectory: String?) -> AISessionSnapshot? {
        snapshotForMatchedAgent(
            proc: proc,
            workingDirectory: workingDirectory,
            resolvedProcessCwd: processCwd(pid: proc.pid)
        )
    }

    static func snapshotForMatchedAgent(
        proc: ProcessInfo,
        workingDirectory: String?,
        resolvedProcessCwd: String?,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> AISessionSnapshot? {
        let execName = (proc.command as NSString).lastPathComponent

        // Claude Code detection: binary is named "claude"
        if execName == "claude" || proc.command.hasSuffix("/claude") {
            let resolvedCwd = resolvedProcessCwd ?? workingDirectory
            let sessionInfo = resolveClaudeSessionId(pid: proc.pid, workingDirectory: resolvedCwd)
            return AISessionSnapshot(
                agentType: .claudeCode,
                sessionId: sessionInfo?.sessionId,
                workingDirectory: resolvedCwd,
                command: proc.fullCommand,
                projectPath: sessionInfo?.projectPath,
                lastSeenActive: now
            )
        }

        // Codex detection: binary named "codex"
        if execName == "codex" || proc.command.hasSuffix("/codex") {
            let resolvedCwd = resolvedProcessCwd ?? workingDirectory
            return AISessionSnapshot(
                agentType: .codex,
                sessionId: nil,
                workingDirectory: resolvedCwd,
                command: proc.fullCommand,
                projectPath: resolvedCwd,
                lastSeenActive: now
            )
        }

        return nil
    }

    // MARK: - Claude Code Session ID Resolution (v2: PID-correlated)

    struct ClaudeSessionInfo {
        let sessionId: String
        let projectPath: String?
        /// How confident we are in the match (lower = better).
        let score: Int
    }

    /// Resolves the Claude Code session ID for a specific PID by correlating
    /// process start time with .jsonl entry timestamps.
    ///
    /// Algorithm:
    /// 1. Get PID's CWD → encode to Claude project dir
    /// 2. Get PID's start time (epoch)
    /// 3. For each .jsonl modified after PID start, find first entry >= PID start
    /// 4. Score: new sessions (match at line 0-4) score by delta alone;
    ///    resumed-by-other-PID sessions (mid-file match) get +1000 penalty
    /// 5. Lowest score wins
    static func resolveClaudeSessionId(pid: pid_t, workingDirectory: String?) -> ClaudeSessionInfo? {
        guard let cwd = workingDirectory, !cwd.isEmpty else { return nil }
        guard let startEpoch = processStartEpoch(pid: pid) else { return nil }

        let claudeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let projectDir = findClaudeProjectDir(claudeDir: claudeBase, workingDirectory: cwd) else {
            return nil
        }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: projectDir.path) else { return nil }

        struct Candidate {
            let sessionId: String
            let delta: Int
            let matchLine: Int
            let isNewSession: Bool
            let score: Int
        }

        var candidates: [Candidate] = []

        for filename in contents {
            guard filename.hasSuffix(".jsonl") else { continue }
            let filePath = projectDir.appendingPathComponent(filename).path

            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                  mtime >= Double(startEpoch) else { continue }

            let sessionId = String(filename.dropLast(6)) // remove ".jsonl"

            guard let firstAfter = findFirstEntryAfter(
                epoch: startEpoch,
                inFile: filePath
            ) else { continue }

            // Sessions where the match is in the first 5 lines were likely CREATED by this PID.
            // Mid-file matches mean another PID was already writing to this file.
            let isNewSession = firstAfter.line < 5
            let score = firstAfter.delta + (isNewSession ? 0 : 1000)

            candidates.append(Candidate(
                sessionId: sessionId,
                delta: firstAfter.delta,
                matchLine: firstAfter.line,
                isNewSession: isNewSession,
                score: score
            ))
        }

        guard let best = candidates.min(by: { $0.score < $1.score }) else { return nil }

        // Read project path from the index if available
        let projectPath = readProjectPath(from: projectDir)

        return ClaudeSessionInfo(
            sessionId: best.sessionId,
            projectPath: projectPath,
            score: best.score
        )
    }

    // MARK: - JSONL Entry Scanning

    private struct EntryMatch {
        let line: Int
        let epoch: Int
        let delta: Int
    }

    /// Scans a .jsonl file for the first entry with a timestamp >= the given epoch.
    /// Returns the line number and time delta, or nil if no match found.
    private static func findFirstEntryAfter(epoch: Int, inFile path: String) -> EntryMatch? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        // Read in chunks to avoid loading huge files entirely into memory
        let chunkSize = 64 * 1024
        var lineIndex = 0
        var remainder = ""

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty && remainder.isEmpty { break }

            let text = remainder + (String(data: chunk, encoding: .utf8) ?? "")
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)

            // Last element might be incomplete if chunk didn't end on newline
            if chunk.count == chunkSize {
                remainder = String(lines.removeLast())
            } else {
                remainder = ""
            }

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    lineIndex += 1
                    continue
                }

                if let entryEpoch = extractTimestampEpoch(from: trimmed) {
                    if entryEpoch >= epoch {
                        return EntryMatch(
                            line: lineIndex,
                            epoch: entryEpoch,
                            delta: entryEpoch - epoch
                        )
                    }
                }
                lineIndex += 1
            }

            if chunk.isEmpty { break }
        }

        return nil
    }

    /// Fast timestamp extraction from a JSON line without full JSON parsing.
    /// Looks for "timestamp":"2026-03-13T14:28:09.094Z" pattern.
    private static func extractTimestampEpoch(from line: String) -> Int? {
        // Fast path: find "timestamp":" pattern
        guard let range = line.range(of: "\"timestamp\":\"") else { return nil }
        let afterKey = line[range.upperBound...]
        guard let endQuote = afterKey.firstIndex(of: "\"") else { return nil }
        let tsString = String(afterKey[..<endQuote])

        return parseISO8601Epoch(tsString)
    }

    /// Parse ISO8601 timestamp string to Unix epoch (seconds).
    static func parseISO8601Epoch(_ string: String) -> Int? {
        // Handle "2026-03-13T14:28:09.094Z" format
        // Fast manual parse to avoid DateFormatter overhead
        guard string.count >= 19 else { return nil }
        let idx = string.startIndex

        guard let year = Int(string[idx..<string.index(idx, offsetBy: 4)]),
              let month = Int(string[string.index(idx, offsetBy: 5)..<string.index(idx, offsetBy: 7)]),
              let day = Int(string[string.index(idx, offsetBy: 8)..<string.index(idx, offsetBy: 10)]),
              let hour = Int(string[string.index(idx, offsetBy: 11)..<string.index(idx, offsetBy: 13)]),
              let minute = Int(string[string.index(idx, offsetBy: 14)..<string.index(idx, offsetBy: 16)]),
              let second = Int(string[string.index(idx, offsetBy: 17)..<string.index(idx, offsetBy: 19)])
        else { return nil }

        // Convert to Unix epoch using Calendar
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        // Timestamps ending in Z are UTC
        if string.hasSuffix("Z") {
            components.timeZone = TimeZone(identifier: "UTC")
        }

        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    // MARK: - Process Introspection

    /// Get the current working directory of a process via lsof.
    static func processCwd(pid: pid_t) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            if line.hasPrefix("n") && line != "n" {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    /// Get the start time of a process as Unix epoch (seconds).
    static func processStartEpoch(pid: pid_t) -> Int? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "lstart=", "-p", "\(pid)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }

        // macOS `ps -o lstart=` format: "Fri 13 Mar 14:34:25 2026"
        return parseMacOSLstart(output)
    }

    /// Parse macOS `ps -o lstart=` output to epoch.
    /// Format: "Fri 13 Mar 14:34:25 2026" or "Fri Mar 13 14:34:25 2026"
    static func parseMacOSLstart(_ string: String) -> Int? {
        let formats = [
            "EEE dd MMM HH:mm:ss yyyy",  // "Fri 13 Mar 14:34:25 2026"
            "EEE MMM dd HH:mm:ss yyyy",  // "Fri Mar 13 14:34:25 2026"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return Int(date.timeIntervalSince1970)
            }
        }
        return nil
    }

    // MARK: - Project Directory Resolution

    /// Finds the Claude project directory matching a working directory.
    /// Claude encodes "/Users/tim/project" as "-Users-tim-project".
    static func findClaudeProjectDir(claudeDir: URL, workingDirectory: String) -> URL? {
        let encoded = workingDirectory.replacingOccurrences(of: "/", with: "-")
        let candidate = claudeDir.appendingPathComponent(encoded)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        // Walk up the directory tree to find a matching parent project
        var searchPath = workingDirectory
        while !searchPath.isEmpty && searchPath != "/" {
            searchPath = (searchPath as NSString).deletingLastPathComponent
            let encodedSearch = searchPath.replacingOccurrences(of: "/", with: "-")
            let parentCandidate = claudeDir.appendingPathComponent(encodedSearch)
            if FileManager.default.fileExists(atPath: parentCandidate.path) {
                return parentCandidate
            }
        }

        return nil
    }

    /// Read the original project path from sessions-index.json.
    private static func readProjectPath(from projectDir: URL) -> String? {
        let indexFile = projectDir.appendingPathComponent("sessions-index.json")
        guard let data = try? Data(contentsOf: indexFile),
              let index = try? JSONDecoder().decode(ClaudeSessionsIndex.self, from: data) else {
            return nil
        }
        return index.originalPath
    }

    // MARK: - Process Table Queries

    /// Returns processes attached to a given TTY device name (e.g. "/dev/ttys042").
    static func childProcesses(forTTY ttyName: String) -> [ProcessInfo] {
        let shortTTY = ttyName.hasPrefix("/dev/") ? String(ttyName.dropFirst(5)) : ttyName

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", shortTTY, "-o", "pid=,command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return parseProcessList(output)
    }

    /// Returns child processes of a given parent PID.
    private static func childProcesses(forParentPID ppid: pid_t) -> [ProcessInfo] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,command=", "-g", "\(ppid)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return parseProcessList(output)
    }

    static func parseProcessList(_ output: String) -> [ProcessInfo] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(of: " ") else { return nil }
            let pidStr = trimmed[..<firstSpace].trimmingCharacters(in: .whitespaces)
            guard let pid = pid_t(pidStr) else { return nil }
            let fullCommand = trimmed[trimmed.index(after: firstSpace)...].trimmingCharacters(in: .whitespaces)
            let args = fullCommand.split(separator: " ").map(String.init)
            let command = args.first ?? fullCommand
            return ProcessInfo(pid: pid, command: command, args: args, fullCommand: fullCommand)
        }
    }
}

// MARK: - Claude Sessions Index Model

struct ClaudeSessionsIndex: Decodable {
    let entries: [ClaudeSessionEntry]
    let originalPath: String?
}

struct ClaudeSessionEntry: Decodable {
    let sessionId: String
    let fileMtime: Double?
    let firstPrompt: String?
    let messageCount: Int?
    let created: String?
    let modified: String?
    let gitBranch: String?
    let projectPath: String?
}
