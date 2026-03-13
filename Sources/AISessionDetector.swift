import Foundation

// MARK: - AI Session Detection for Terminal Panels
//
// Detects running AI coding agents (Claude Code, Codex, etc.) in terminal panels
// by inspecting child processes of the shell via the PTY name. Captures session
// identifiers so that sessions can be automatically resumed after a crash or restart.

/// Identifies the type of AI coding agent detected in a terminal.
enum AIAgentType: String, Codable, Sendable {
    case claudeCode = "claude_code"
    case codex = "codex"
}

/// Snapshot of a detected AI agent session, persisted alongside the panel snapshot.
struct AISessionSnapshot: Codable, Sendable, Equatable {
    /// The type of agent that was running.
    var agentType: AIAgentType

    /// The session/conversation identifier, if detectable.
    /// For Claude Code this is the UUID from ~/.claude/projects/.../sessions-index.json
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
            // Codex doesn't have a resume flag — just restart in the same directory
            return command ?? "codex"
        }
    }
}

/// Detects AI coding agents running inside terminal sessions.
enum AISessionDetector {

    // MARK: - Process Detection

    /// Detect an AI agent running under the given TTY.
    /// Returns nil if no known agent is found.
    static func detect(ttyName: String?, workingDirectory: String?) -> AISessionSnapshot? {
        guard let ttyName, !ttyName.isEmpty else { return nil }

        // Get all processes attached to this TTY
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

    private struct ProcessInfo {
        let pid: pid_t
        let command: String
        let args: [String]
        let fullCommand: String
    }

    private static func matchAgent(proc: ProcessInfo, workingDirectory: String?) -> AISessionSnapshot? {
        let execName = (proc.command as NSString).lastPathComponent

        // Claude Code detection: binary is named "claude"
        if execName == "claude" || proc.command.hasSuffix("/claude") {
            let sessionId = resolveClaudeSessionId(workingDirectory: workingDirectory)
            return AISessionSnapshot(
                agentType: .claudeCode,
                sessionId: sessionId?.sessionId,
                workingDirectory: workingDirectory,
                command: proc.fullCommand,
                projectPath: sessionId?.projectPath,
                lastSeenActive: Date().timeIntervalSince1970
            )
        }

        // Codex detection: binary named "codex"
        if execName == "codex" || proc.command.hasSuffix("/codex") {
            return AISessionSnapshot(
                agentType: .codex,
                sessionId: nil,
                workingDirectory: workingDirectory,
                command: proc.fullCommand,
                projectPath: workingDirectory,
                lastSeenActive: Date().timeIntervalSince1970
            )
        }

        return nil
    }

    // MARK: - Claude Code Session ID Resolution

    private struct ClaudeSessionInfo {
        let sessionId: String
        let projectPath: String?
    }

    /// Finds the most recent active Claude Code session for a given working directory
    /// by reading the sessions-index.json from ~/.claude/projects/.
    private static func resolveClaudeSessionId(workingDirectory: String?) -> ClaudeSessionInfo? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }

        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        // Find the project directory that matches this working directory.
        // Claude Code encodes paths by replacing "/" with "-" and prepending "-".
        guard let projectDir = findClaudeProjectDir(claudeDir: claudeDir, workingDirectory: workingDirectory) else {
            return nil
        }

        let indexFile = projectDir.appendingPathComponent("sessions-index.json")
        guard let data = try? Data(contentsOf: indexFile) else { return nil }

        // Parse the sessions index to find the most recently modified session.
        guard let index = try? JSONDecoder().decode(ClaudeSessionsIndex.self, from: data) else { return nil }

        // Sort by modified date descending, pick the most recent.
        let sorted = index.sessions.sorted { lhs, rhs in
            (lhs.fileMtime ?? 0) > (rhs.fileMtime ?? 0)
        }

        guard let mostRecent = sorted.first else { return nil }

        return ClaudeSessionInfo(
            sessionId: mostRecent.sessionId,
            projectPath: index.originalPath
        )
    }

    /// Finds the Claude project directory matching a working directory.
    private static func findClaudeProjectDir(claudeDir: URL, workingDirectory: String) -> URL? {
        // Claude encodes "/Users/tim/project" as "-Users-tim-project"
        let encoded = workingDirectory.replacingOccurrences(of: "/", with: "-")

        let candidateDirs: [URL] = [
            claudeDir.appendingPathComponent(encoded),
        ]

        for candidate in candidateDirs {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Fallback: walk up the directory tree to find a matching project
        var searchPath = workingDirectory
        while !searchPath.isEmpty && searchPath != "/" {
            let encodedSearch = searchPath.replacingOccurrences(of: "/", with: "-")
            let candidate = claudeDir.appendingPathComponent(encodedSearch)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searchPath = (searchPath as NSString).deletingLastPathComponent
        }

        return nil
    }

    // MARK: - Process Table Queries

    /// Returns processes attached to a given TTY device name (e.g. "/dev/ttys042").
    private static func childProcesses(forTTY ttyName: String) -> [ProcessInfo] {
        // Strip "/dev/" prefix if present for matching
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
        } catch {
            return []
        }

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
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return parseProcessList(output)
    }

    private static func parseProcessList(_ output: String) -> [ProcessInfo] {
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

private struct ClaudeSessionsIndex: Decodable {
    let sessions: [ClaudeSessionEntry]
    let originalPath: String?
}

private struct ClaudeSessionEntry: Decodable {
    let sessionId: String
    let fileMtime: Double?
    let firstPrompt: String?
    let messageCount: Int?
    let created: String?
    let modified: String?
    let gitBranch: String?
    let projectPath: String?
}
