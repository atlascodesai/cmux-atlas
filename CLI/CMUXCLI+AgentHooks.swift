import Foundation

private struct ClaudeHookParsedInput {
    let rawInput: String
    let object: [String: Any]?
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
}

private struct CodexHookParsedInput {
    let rawInput: String
    let object: [String: Any]?
    let sessionId: String?
    let cwd: String?
    let transcriptPath: String?
    let permissionMode: String?
    let source: String?
}

private struct ClaudeHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var pid: Int?
    var lastSubtitle: String?
    var lastBody: String?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
}

private struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
}

private final class ClaudeHookSessionStore {
    private static let defaultStatePath = "~/.cmuxterm/claude-hook-sessions.json"
    private static let maxStateAgeSeconds: TimeInterval = 60 * 60 * 24 * 7

    private let statePath: String
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        if let overridePath = processEnv["CMUX_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.statePath = NSString(string: overridePath).expandingTildeInPath
        } else {
            self.statePath = NSString(string: Self.defaultStatePath).expandingTildeInPath
        }
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func lookup(sessionId: String) throws -> ClaudeHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            state.sessions[normalized]
        }
    }

    func upsert(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        pid: Int? = nil,
        lastSubtitle: String? = nil,
        lastBody: String? = nil
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalized] ?? ClaudeHookSessionRecord(
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: nil,
                pid: nil,
                lastSubtitle: nil,
                lastBody: nil,
                startedAt: now,
                updatedAt: now
            )
            record.workspaceId = workspaceId
            if !surfaceId.isEmpty {
                record.surfaceId = surfaceId
            }
            if let cwd = normalizeOptional(cwd) {
                record.cwd = cwd
            }
            if let pid {
                record.pid = pid
            }
            if let subtitle = normalizeOptional(lastSubtitle) {
                record.lastSubtitle = subtitle
            }
            if let body = normalizeOptional(lastBody) {
                record.lastBody = body
            }
            record.updatedAt = now
            state.sessions[normalized] = record
        }
    }

    func consume(
        sessionId: String?,
        workspaceId: String?,
        surfaceId: String?
    ) throws -> ClaudeHookSessionRecord? {
        let normalizedSessionId = normalizeOptional(sessionId)
        let normalizedWorkspace = normalizeOptional(workspaceId)
        let normalizedSurface = normalizeOptional(surfaceId)
        return try withLockedState { state in
            if let normalizedSessionId,
               let removed = state.sessions.removeValue(forKey: normalizedSessionId) {
                return removed
            }

            guard let fallback = fallbackRecord(
                sessions: Array(state.sessions.values),
                workspaceId: normalizedWorkspace,
                surfaceId: normalizedSurface
            ) else {
                return nil
            }
            state.sessions.removeValue(forKey: fallback.sessionId)
            return fallback
        }
    }

    private func fallbackRecord(
        sessions: [ClaudeHookSessionRecord],
        workspaceId: String?,
        surfaceId: String?
    ) -> ClaudeHookSessionRecord? {
        if let surfaceId {
            let matches = sessions.filter { $0.surfaceId == surfaceId }
            return matches.max(by: { $0.updatedAt < $1.updatedAt })
        }
        if let workspaceId {
            let matches = sessions.filter { $0.workspaceId == workspaceId }
            if matches.count == 1 {
                return matches[0]
            }
        }
        return nil
    }

    private func withLockedState<T>(_ body: (inout ClaudeHookSessionStoreFile) throws -> T) throws -> T {
        let stateURL = URL(fileURLWithPath: statePath)
        let parentURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)

        let lockPath = statePath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open Claude hook state lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock Claude hook state: \(lockPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var state = loadUnlocked()
        pruneExpired(&state)
        let result = try body(&state)
        try saveUnlocked(state)
        return result
    }

    private func loadUnlocked() -> ClaudeHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath) else {
            return ClaudeHookSessionStoreFile()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let decoded = try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data) else {
            return ClaudeHookSessionStoreFile()
        }
        return decoded
    }

    private func saveUnlocked(_ state: ClaudeHookSessionStoreFile) throws {
        let stateURL = URL(fileURLWithPath: statePath)
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func pruneExpired(_ state: inout ClaudeHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Self.maxStateAgeSeconds
        state.sessions = state.sessions.filter { _, record in
            record.updatedAt >= cutoff
        }
    }

    private func normalizeSessionId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct CodexHookSessionRecord: Codable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var transcriptPath: String?
    var permissionMode: String?
    var source: String?
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
}

private struct CodexHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: CodexHookSessionRecord] = [:]
}

private final class CodexHookSessionStore {
    private static let defaultStatePath = "~/.cmuxterm/codex-hook-sessions.json"
    private static let maxStateAgeSeconds: TimeInterval = 60 * 60 * 24 * 7

    private let statePath: String
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        if let overridePath = processEnv["CMUX_CODEX_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.statePath = NSString(string: overridePath).expandingTildeInPath
        } else {
            self.statePath = NSString(string: Self.defaultStatePath).expandingTildeInPath
        }
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func lookup(sessionId: String) throws -> CodexHookSessionRecord? {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return nil }
        return try withLockedState { state in
            state.sessions[normalized]
        }
    }

    func upsert(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        cwd: String?,
        transcriptPath: String? = nil,
        permissionMode: String? = nil,
        source: String? = nil
    ) throws {
        let normalized = normalizeSessionId(sessionId)
        guard !normalized.isEmpty else { return }
        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalized] ?? CodexHookSessionRecord(
                sessionId: normalized,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: nil,
                transcriptPath: nil,
                permissionMode: nil,
                source: nil,
                startedAt: now,
                updatedAt: now
            )
            record.workspaceId = workspaceId
            if !surfaceId.isEmpty {
                record.surfaceId = surfaceId
            }
            if let cwd = normalizeOptional(cwd) {
                record.cwd = cwd
            }
            if let transcriptPath = normalizeOptional(transcriptPath) {
                record.transcriptPath = transcriptPath
            }
            if let permissionMode = normalizeOptional(permissionMode) {
                record.permissionMode = permissionMode
            }
            if let source = normalizeOptional(source) {
                record.source = source
            }
            record.updatedAt = now
            state.sessions[normalized] = record
        }
    }

    private func withLockedState<T>(_ body: (inout CodexHookSessionStoreFile) throws -> T) throws -> T {
        let stateURL = URL(fileURLWithPath: statePath)
        let parentURL = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)

        let lockPath = statePath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open Codex hook state lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock Codex hook state: \(lockPath)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        var state = loadUnlocked()
        pruneExpired(&state)
        let result = try body(&state)
        try saveUnlocked(state)
        return result
    }

    private func loadUnlocked() -> CodexHookSessionStoreFile {
        guard fileManager.fileExists(atPath: statePath) else {
            return CodexHookSessionStoreFile()
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let decoded = try? decoder.decode(CodexHookSessionStoreFile.self, from: data) else {
            return CodexHookSessionStoreFile()
        }
        return decoded
    }

    private func saveUnlocked(_ state: CodexHookSessionStoreFile) throws {
        let stateURL = URL(fileURLWithPath: statePath)
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func pruneExpired(_ state: inout CodexHookSessionStoreFile) {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Self.maxStateAgeSeconds
        state.sessions = state.sessions.filter { _, record in
            record.updatedAt >= cutoff
        }
    }

    private func normalizeSessionId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension CMUXCLI {
    func runClaudeHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parsedInput = parseClaudeHookInput(rawInput: rawInput)
        let sessionStore = ClaudeHookSessionStore()
        telemetry.breadcrumb(
            "claude-hook.input",
            data: [
                "subcommand": subcommand,
                "has_session_id": parsedInput.sessionId != nil,
                "has_workspace_flag": hookWsFlag != nil,
                "has_surface_flag": optionValue(hookArgs, name: "--surface") != nil
            ]
        )
        let fallbackWorkspaceId = try resolveWorkspaceIdForAgentHook(workspaceArg, client: client)
        let fallbackSurfaceId = try? resolveSurfaceId(surfaceArg, workspaceId: fallbackWorkspaceId, client: client)

        switch subcommand {
        case "session-start", "active":
            telemetry.breadcrumb("claude-hook.session-start")
            let workspaceId = fallbackWorkspaceId
            let surfaceId = try resolveSurfaceIdForAgentHook(
                surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            let claudePid: Int? = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_CLAUDE_PID"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    let pid = Int(raw),
                    pid > 0 else {
                    return nil
                }
                return pid
            }()
            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    pid: claudePid
                )
                var activeArgs = "claude_code \(sessionId) --tab=\(workspaceId) --surface=\(surfaceId)"
                if let cwd = parsedInput.cwd, !cwd.isEmpty {
                    activeArgs += " --cwd=\(cwd) --project=\(cwd)"
                }
                if let claudePid {
                    activeArgs += " --pid=\(claudePid)"
                }
                _ = try? sendV1Command("set_active_ai_session \(activeArgs)", client: client)
            }
            if let claudePid {
                _ = try? sendV1Command(
                    "set_agent_pid claude_code \(claudePid) --tab=\(workspaceId)",
                    client: client
                )
            }
            print("OK")

        case "stop", "idle":
            telemetry.breadcrumb("claude-hook.stop")
            var workspaceId = fallbackWorkspaceId
            var surfaceId = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForAgentHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                surfaceId = mapped.surfaceId
            }

            let completion = summarizeClaudeHookStop(
                parsedInput: parsedInput,
                sessionRecord: (try? sessionStore.lookup(sessionId: parsedInput.sessionId ?? ""))
            )
            if let sessionId = parsedInput.sessionId, let completion {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId ?? "",
                    cwd: parsedInput.cwd,
                    lastSubtitle: completion.subtitle,
                    lastBody: completion.body
                )
            }

            if let completion {
                let resolvedSurface = try resolveSurfaceIdForAgentHook(
                    surfaceId,
                    workspaceId: workspaceId,
                    client: client
                )
                let title = "Claude Code"
                let subtitle = sanitizeNotificationField(completion.subtitle)
                let body = sanitizeNotificationField(completion.body)
                let payload = "\(title)|\(subtitle)|\(body)"
                _ = try? sendV1Command("notify_target \(workspaceId) \(resolvedSurface) \(payload)", client: client)
            }

            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Idle",
                icon: "pause.circle.fill",
                color: "#8E8E93"
            )
            print("OK")

        case "prompt-submit":
            telemetry.breadcrumb("claude-hook.prompt-submit")
            var workspaceId = fallbackWorkspaceId
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForAgentHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
            }
            _ = try sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Running",
                icon: "bolt.fill",
                color: "#4C8DFF"
            )
            print("OK")

        case "notification", "notify":
            telemetry.breadcrumb("claude-hook.notification")
            var summary = summarizeClaudeHookNotification(rawInput: rawInput)

            var workspaceId = fallbackWorkspaceId
            var preferredSurface = surfaceArg
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForAgentHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                preferredSurface = mapped.surfaceId
                if let savedBody = mapped.lastBody, !savedBody.isEmpty,
                   summary.body.contains("needs your attention") || summary.body.contains("needs your input") {
                    summary = (subtitle: mapped.lastSubtitle ?? summary.subtitle, body: savedBody)
                }
            }

            let surfaceId = try resolveSurfaceIdForAgentHook(
                preferredSurface,
                workspaceId: workspaceId,
                client: client
            )

            let title = "Claude Code"
            let subtitle = sanitizeNotificationField(summary.subtitle)
            let body = sanitizeNotificationField(summary.body)
            let payload = "\(title)|\(subtitle)|\(body)"

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body
                )
            }

            let response = try client.send(command: "notify_target \(workspaceId) \(surfaceId) \(payload)")
            _ = try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            print(response)

        case "session-end":
            telemetry.breadcrumb("claude-hook.session-end")
            if let sessionId = parsedInput.sessionId, !sessionId.isEmpty {
                let record = try? sessionStore.lookup(sessionId: sessionId)
                let resolvedWorkspace = record?.workspaceId ?? fallbackWorkspaceId
                let resolvedSurface = record?.surfaceId ?? fallbackSurfaceId
                let resumeCWD = parsedInput.cwd ?? record?.cwd
                var resumeArgs = "\(sessionId) --tab=\(resolvedWorkspace)"
                if let surface = resolvedSurface, !surface.isEmpty {
                    resumeArgs += " --surface=\(surface)"
                }
                if let cwd = resumeCWD, !cwd.isEmpty {
                    resumeArgs += " --cwd=\(cwd) --project=\(cwd)"
                }
                _ = try? sendV1Command("prefill_session_resume \(resumeArgs)", client: client)
                var clearActiveArgs = "claude_code --tab=\(resolvedWorkspace)"
                if let surface = resolvedSurface, !surface.isEmpty {
                    clearActiveArgs += " --surface=\(surface)"
                }
                _ = try? sendV1Command("clear_active_ai_session \(clearActiveArgs)", client: client)
            }

            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: fallbackWorkspaceId,
                surfaceId: fallbackSurfaceId
            )
            if let consumedSession {
                let workspaceId = consumedSession.workspaceId
                _ = try? clearClaudeStatus(client: client, workspaceId: workspaceId)
                _ = try? sendV1Command("clear_agent_pid claude_code --tab=\(workspaceId)", client: client)
                _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            }
            print("OK")

        case "pre-tool-use":
            telemetry.breadcrumb("claude-hook.pre-tool-use")
            var workspaceId = fallbackWorkspaceId
            var claudePid: Int? = nil
            if let sessionId = parsedInput.sessionId,
               let mapped = try? sessionStore.lookup(sessionId: sessionId),
               let mappedWorkspace = try? resolveWorkspaceIdForAgentHook(mapped.workspaceId, client: client) {
                workspaceId = mappedWorkspace
                claudePid = mapped.pid
            }

            if let toolName = parsedInput.object?["tool_name"] as? String,
               toolName == "AskUserQuestion",
               let question = describeAskUserQuestion(parsedInput.object),
               let sessionId = parsedInput.sessionId {
                let existingSurfaceId = (try? sessionStore.lookup(sessionId: sessionId))?.surfaceId ?? ""
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: existingSurfaceId,
                    cwd: parsedInput.cwd,
                    lastSubtitle: "Waiting",
                    lastBody: question
                )
                print("OK")
                return
            }

            _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)

            let statusValue: String
            if UserDefaults.standard.bool(forKey: "claudeCodeVerboseStatus"),
               let toolStatus = describeToolUse(parsedInput.object) {
                statusValue = toolStatus
            } else {
                statusValue = "Running"
            }
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                value: statusValue,
                icon: "bolt.fill",
                color: "#4C8DFF",
                pid: claudePid
            )
            print("OK")

        case "help", "--help", "-h":
            telemetry.breadcrumb("claude-hook.help")
            print(
                """
                cmux claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use> [--workspace <id|index>] [--surface <id|index>]
                """
            )

        default:
            throw CLIError(message: "Unknown claude-hook subcommand: \(subcommand)")
        }
    }

    func runCodexHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parsedInput = parseCodexHookInput(rawInput: rawInput)
        let sessionStore = CodexHookSessionStore()
        telemetry.breadcrumb(
            "codex-hook.input",
            data: [
                "subcommand": subcommand,
                "has_session_id": parsedInput.sessionId != nil,
                "has_workspace_flag": hookWsFlag != nil,
                "has_surface_flag": optionValue(hookArgs, name: "--surface") != nil
            ]
        )
        let fallbackWorkspaceId = try resolveWorkspaceIdForAgentHook(workspaceArg, client: client)

        switch subcommand {
        case "session-start", "active":
            telemetry.breadcrumb("codex-hook.session-start")
            guard let sessionId = parsedInput.sessionId else {
                throw CLIError(message: "codex-hook session-start requires session_id in stdin JSON")
            }
            let workspaceId = fallbackWorkspaceId
            let surfaceId = try resolveSurfaceIdForAgentHook(
                surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            try? sessionStore.upsert(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: parsedInput.cwd,
                transcriptPath: parsedInput.transcriptPath,
                permissionMode: parsedInput.permissionMode,
                source: parsedInput.source
            )
            let codexPid: Int? = {
                guard let raw = ProcessInfo.processInfo.environment["CMUX_CODEX_PID"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    let pid = Int(raw),
                    pid > 0 else {
                    return nil
                }
                return pid
            }()
            var activeArgs = "codex \(sessionId) --tab=\(workspaceId) --surface=\(surfaceId)"
            if let cwd = parsedInput.cwd, !cwd.isEmpty {
                activeArgs += " --cwd=\(cwd) --project=\(cwd)"
            }
            if let codexPid {
                activeArgs += " --pid=\(codexPid)"
            }
            _ = try? sendV1Command("set_active_ai_session \(activeArgs)", client: client)
            print("{\"continue\":true}")

        case "prompt-submit":
            telemetry.breadcrumb("codex-hook.prompt-submit")
            guard let sessionId = parsedInput.sessionId else {
                print("{\"continue\":true}")
                return
            }
            let existingRecord = try? sessionStore.lookup(sessionId: sessionId)
            let workspaceId = existingRecord?.workspaceId ?? fallbackWorkspaceId
            _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            try setCodexStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Running",
                icon: "bolt.fill",
                color: "#4C8DFF"
            )
            print("{\"continue\":true}")

        case "stop", "idle":
            telemetry.breadcrumb("codex-hook.stop")
            guard let sessionId = parsedInput.sessionId else {
                print("{\"continue\":true}")
                return
            }
            let existingRecord = try? sessionStore.lookup(sessionId: sessionId)
            let workspaceId = existingRecord?.workspaceId ?? fallbackWorkspaceId
            let resolvedSurfaceId = try resolveSurfaceIdForAgentHook(
                existingRecord?.surfaceId ?? surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            try? sessionStore.upsert(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: resolvedSurfaceId,
                cwd: parsedInput.cwd ?? existingRecord?.cwd,
                transcriptPath: parsedInput.transcriptPath ?? existingRecord?.transcriptPath,
                permissionMode: parsedInput.permissionMode ?? existingRecord?.permissionMode,
                source: parsedInput.source ?? existingRecord?.source
            )
            try? setCodexStatus(
                client: client,
                workspaceId: workspaceId,
                value: "Idle",
                icon: "pause.circle.fill",
                color: "#8E8E93"
            )
            print("{\"continue\":true}")

        case "help", "--help", "-h":
            telemetry.breadcrumb("codex-hook.help")
            print(
                """
                cmux codex-hook <session-start|prompt-submit|stop> [--workspace <id|index>] [--surface <id|index>]
                """
            )

        default:
            throw CLIError(message: "Unknown codex-hook subcommand: \(subcommand)")
        }
    }

    private func setClaudeStatus(
        client: SocketClient,
        workspaceId: String,
        value: String,
        icon: String,
        color: String,
        pid: Int? = nil
    ) throws {
        var cmd = "set_status claude_code \(value) --icon=\(icon) --color=\(color) --tab=\(workspaceId)"
        if let pid {
            cmd += " --pid=\(pid)"
        }
        _ = try client.send(command: cmd)
    }

    private func clearClaudeStatus(client: SocketClient, workspaceId: String) throws {
        _ = try client.send(command: "clear_status claude_code --tab=\(workspaceId)")
    }

    private func setCodexStatus(
        client: SocketClient,
        workspaceId: String,
        value: String,
        icon: String,
        color: String
    ) throws {
        _ = try client.send(command: "set_status codex \(value) --icon=\(icon) --color=\(color) --tab=\(workspaceId)")
    }

    private func describeAskUserQuestion(_ object: [String: Any]?) -> String? {
        guard let object,
              let input = object["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first else { return nil }

        var parts: [String] = []

        if let question = first["question"] as? String, !question.isEmpty {
            parts.append(question)
        } else if let header = first["header"] as? String, !header.isEmpty {
            parts.append(header)
        }

        if let options = first["options"] as? [[String: Any]] {
            let labels = options.compactMap { $0["label"] as? String }
            if !labels.isEmpty {
                parts.append(labels.map { "[\($0)]" }.joined(separator: " "))
            }
        }

        if parts.isEmpty { return "Asking a question" }
        return parts.joined(separator: "\n")
    }

    private func describeToolUse(_ object: [String: Any]?) -> String? {
        guard let object, let toolName = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any]

        switch toolName {
        case "Read":
            if let path = input?["file_path"] as? String {
                return "Reading \(shortenPath(path))"
            }
            return "Reading file"
        case "Edit":
            if let path = input?["file_path"] as? String {
                return "Editing \(shortenPath(path))"
            }
            return "Editing file"
        case "Write":
            if let path = input?["file_path"] as? String {
                return "Writing \(shortenPath(path))"
            }
            return "Writing file"
        case "Bash":
            if let cmd = input?["command"] as? String {
                let first = cmd.components(separatedBy: .whitespacesAndNewlines).first ?? cmd
                let short = String(first.prefix(30))
                return "Running \(short)"
            }
            return "Running command"
        case "Glob":
            if let pattern = input?["pattern"] as? String {
                return "Searching \(String(pattern.prefix(30)))"
            }
            return "Searching files"
        case "Grep":
            if let pattern = input?["pattern"] as? String {
                return "Grep \(String(pattern.prefix(30)))"
            }
            return "Searching code"
        case "Agent":
            if let desc = input?["description"] as? String {
                return String(desc.prefix(40))
            }
            return "Subagent"
        case "WebFetch":
            return "Fetching URL"
        case "WebSearch":
            if let query = input?["query"] as? String {
                return "Search: \(String(query.prefix(30)))"
            }
            return "Web search"
        default:
            return toolName
        }
    }

    private func shortenPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return name.isEmpty ? String(path.suffix(30)) : name
    }

    private func resolveWorkspaceIdForAgentHook(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, !raw.isEmpty, let candidate = try? resolveWorkspaceId(raw, client: client) {
            let probe = try? client.sendV2(method: "surface.list", params: ["workspace_id": candidate])
            if probe != nil {
                return candidate
            }
        }
        return try resolveWorkspaceId(nil, client: client)
    }

    private func resolveSurfaceIdForAgentHook(
        _ raw: String?,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        if let raw, !raw.isEmpty, let candidate = try? resolveSurfaceId(raw, workspaceId: workspaceId, client: client) {
            return candidate
        }
        return try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
    }

    private func parseClaudeHookInput(rawInput: String) -> ClaudeHookParsedInput {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            return ClaudeHookParsedInput(rawInput: rawInput, object: nil, sessionId: nil, cwd: nil, transcriptPath: nil)
        }

        let sessionId = extractClaudeHookSessionId(from: object)
        let cwd = extractClaudeHookCWD(from: object)
        let transcriptPath = firstString(in: object, keys: ["transcript_path", "transcriptPath"])
        return ClaudeHookParsedInput(rawInput: rawInput, object: object, sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)
    }

    private func parseCodexHookInput(rawInput: String) -> CodexHookParsedInput {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            return CodexHookParsedInput(
                rawInput: rawInput,
                object: nil,
                sessionId: nil,
                cwd: nil,
                transcriptPath: nil,
                permissionMode: nil,
                source: nil
            )
        }

        return CodexHookParsedInput(
            rawInput: rawInput,
            object: object,
            sessionId: firstString(in: object, keys: ["session_id", "sessionId"]),
            cwd: firstString(in: object, keys: ["cwd", "working_directory", "workingDirectory"]),
            transcriptPath: firstString(in: object, keys: ["transcript_path", "transcriptPath"]),
            permissionMode: firstString(in: object, keys: ["permission_mode", "permissionMode"]),
            source: firstString(in: object, keys: ["source"])
        )
    }

    private func extractClaudeHookSessionId(from object: [String: Any]) -> String? {
        if let id = firstString(in: object, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let nested = object["notification"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let nested = object["data"] as? [String: Any],
           let id = firstString(in: nested, keys: ["session_id", "sessionId"]) {
            return id
        }
        if let session = object["session"] as? [String: Any],
           let id = firstString(in: session, keys: ["id", "session_id", "sessionId"]) {
            return id
        }
        if let context = object["context"] as? [String: Any],
           let id = firstString(in: context, keys: ["session_id", "sessionId"]) {
            return id
        }
        return nil
    }

    private func extractClaudeHookCWD(from object: [String: Any]) -> String? {
        let cwdKeys = ["cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"]
        if let cwd = firstString(in: object, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["notification"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let nested = object["data"] as? [String: Any],
           let cwd = firstString(in: nested, keys: cwdKeys) {
            return cwd
        }
        if let context = object["context"] as? [String: Any],
           let cwd = firstString(in: context, keys: cwdKeys) {
            return cwd
        }
        return nil
    }

    private func summarizeClaudeHookStop(
        parsedInput: ClaudeHookParsedInput,
        sessionRecord: ClaudeHookSessionRecord?
    ) -> (subtitle: String, body: String)? {
        let cwd = parsedInput.cwd ?? sessionRecord?.cwd
        let transcriptPath = parsedInput.transcriptPath

        let projectName: String? = {
            guard let cwd = cwd, !cwd.isEmpty else { return nil }
            let path = NSString(string: cwd).expandingTildeInPath
            let tail = URL(fileURLWithPath: path).lastPathComponent
            return tail.isEmpty ? path : tail
        }()

        let transcript = transcriptPath.flatMap { readTranscriptSummary(path: $0) }

        if let lastMsg = transcript?.lastAssistantMessage {
            var subtitle = "Completed"
            if let projectName, !projectName.isEmpty {
                subtitle = "Completed in \(projectName)"
            }
            return (subtitle, truncate(lastMsg, maxLength: 200))
        }

        let lastMessage = sessionRecord?.lastBody ?? sessionRecord?.lastSubtitle
        let hasContext = cwd != nil || lastMessage != nil
        guard hasContext else { return nil }

        var body = "Claude session completed"
        if let projectName, !projectName.isEmpty {
            body += " in \(projectName)"
        }
        if let lastMessage, !lastMessage.isEmpty {
            body += ". Last: \(lastMessage)"
        }
        return ("Completed", body)
    }

    private struct TranscriptSummary {
        let lastAssistantMessage: String?
    }

    private func readTranscriptSummary(path: String) -> TranscriptSummary? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")
        var lastAssistantMessage: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant" else {
                continue
            }

            let text = extractMessageText(from: message)
            guard let text, !text.isEmpty else { continue }
            lastAssistantMessage = truncate(normalizedSingleLine(text), maxLength: 120)
        }

        guard lastAssistantMessage != nil else { return nil }
        return TranscriptSummary(lastAssistantMessage: lastAssistantMessage)
    }

    private func extractMessageText(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { block -> String? in
                guard (block["type"] as? String) == "text",
                      let text = block["text"] as? String else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let joined = texts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func summarizeClaudeHookNotification(rawInput: String) -> (subtitle: String, body: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("Waiting", "Claude is waiting for your input")
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = json as? [String: Any] else {
            let fallback = truncate(normalizedSingleLine(trimmed), maxLength: 180)
            return classifyClaudeNotification(signal: fallback, message: fallback)
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"])
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "error", "description"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "error", "description"])
        ]
        let message = messageCandidates.compactMap { $0 }.first ?? "Claude needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    private func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "Claude reported an error" : message
            return ("Error", body)
        }
        if lower.contains("complet") || lower.contains("finish") || lower.contains("done") || lower.contains("success") {
            let body = message.isEmpty ? "Task completed" : message
            return ("Completed", body)
        }
        if lower.contains("idle") || lower.contains("wait") || lower.contains("input") || lower.contains("idle_prompt") {
            let body = message.isEmpty ? "Waiting for input" : message
            return ("Waiting", body)
        }
        if !message.isEmpty, message != "Claude needs your input" {
            return ("Attention", message)
        }
        return ("Attention", "Claude needs your attention")
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func normalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }

    private func sanitizeNotificationField(_ value: String) -> String {
        normalizedSingleLine(value).replacingOccurrences(of: "|", with: "¦")
    }
}
