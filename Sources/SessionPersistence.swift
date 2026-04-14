import AppKit
import CoreGraphics
import Darwin
import Foundation
import UniformTypeIdentifiers
import Bonsplit

enum SessionSnapshotSchema {
    static let currentVersion = 1
}

enum SessionPersistencePolicy {
    static let defaultSidebarWidth: Double = 200
    static let minimumSidebarWidth: Double = 180
    static let maximumSidebarWidth: Double = 600
    static let minimumWindowWidth: Double = 300
    static let minimumWindowHeight: Double = 200
    static let autosaveInterval: TimeInterval = 8.0
    static let maxWindowsPerSnapshot: Int = 12
    static let maxWorkspacesPerWindow: Int = 128
    static let maxPanelsPerWorkspace: Int = 512
    static let maxScrollbackLinesPerTerminal: Int = 4000
    static let maxScrollbackCharactersPerTerminal: Int = 400_000
    static let maxSnapshotBytes: Int = 8_000_000

    static func sanitizedSidebarWidth(_ candidate: Double?) -> Double {
        let fallback = defaultSidebarWidth
        guard let candidate, candidate.isFinite else { return fallback }
        return min(max(candidate, minimumSidebarWidth), maximumSidebarWidth)
    }

    static func truncatedScrollback(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= maxScrollbackCharactersPerTerminal {
            return text
        }
        let initialStart = text.index(text.endIndex, offsetBy: -maxScrollbackCharactersPerTerminal)
        let safeStart = ansiSafeTruncationStart(in: text, initialStart: initialStart)
        return String(text[safeStart...])
    }

    /// If truncation starts in the middle of an ANSI CSI escape sequence, advance
    /// to the first printable character after that sequence to avoid replaying
    /// malformed control bytes.
    private static func ansiSafeTruncationStart(in text: String, initialStart: String.Index) -> String.Index {
        guard initialStart > text.startIndex else { return initialStart }
        let escape = "\u{001B}"

        guard let lastEscape = text[..<initialStart].lastIndex(of: Character(escape)) else {
            return initialStart
        }
        let csiMarker = text.index(after: lastEscape)
        guard csiMarker < text.endIndex, text[csiMarker] == "[" else {
            return initialStart
        }

        // If a final CSI byte exists before the truncation boundary, we are not
        // inside a partial sequence.
        if csiFinalByteIndex(in: text, from: csiMarker, upperBound: initialStart) != nil {
            return initialStart
        }

        // We are inside a CSI sequence. Skip to the first character after the
        // sequence terminator if it exists.
        guard let final = csiFinalByteIndex(in: text, from: csiMarker, upperBound: text.endIndex) else {
            return initialStart
        }
        let next = text.index(after: final)
        return next < text.endIndex ? next : text.endIndex
    }

    private static func csiFinalByteIndex(
        in text: String,
        from csiMarker: String.Index,
        upperBound: String.Index
    ) -> String.Index? {
        var index = text.index(after: csiMarker)
        while index < upperBound {
            guard let scalar = text[index].unicodeScalars.first?.value else {
                index = text.index(after: index)
                continue
            }
            if scalar >= 0x40, scalar <= 0x7E {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}

enum SessionRestorePolicy {
    static func isRunningUnderAutomatedTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CMUX_UI_TEST_MODE"] == "1" {
            return true
        }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCTestBundlePath"] != nil {
            return true
        }
        if environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if environment["XCInjectBundle"] != nil {
            return true
        }
        if environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    static func shouldAttemptRestore(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CMUX_DISABLE_SESSION_RESTORE"] == "1" {
            return false
        }
        if isRunningUnderAutomatedTests(environment: environment) {
            return false
        }

        let extraArgs = arguments.dropFirst()
        if extraArgs.isEmpty {
            return true
        }

        let ignorablePrefixes = [
            "-psn_",
            UITestLaunchManifest.argumentName,
        ]
        let filteredArgs = extraArgs.filter { argument in
            !ignorablePrefixes.contains(where: { argument.hasPrefix($0) })
        }

        // Treat launch arguments as non-restoring only when they look like an
        // actual open intent (e.g. a file path or URL). Updater relaunches and
        // internal harness args should not suppress session restore.
        return !filteredArgs.contains { argument in
            argument.hasPrefix("/") ||
            argument.hasPrefix("file://") ||
            argument.hasPrefix("http://") ||
            argument.hasPrefix("https://")
        }
    }
}

struct SessionRectSnapshot: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct SessionDisplaySnapshot: Codable, Sendable {
    var displayID: UInt32?
    var frame: SessionRectSnapshot?
    var visibleFrame: SessionRectSnapshot?
}

enum SessionSidebarSelection: String, Codable, Sendable, Equatable {
    case tabs
    case notifications

    init(selection: SidebarSelection) {
        switch selection {
        case .tabs:
            self = .tabs
        case .notifications:
            self = .notifications
        }
    }

    var sidebarSelection: SidebarSelection {
        switch self {
        case .tabs:
            return .tabs
        case .notifications:
            return .notifications
        }
    }
}

struct SessionSidebarSnapshot: Codable, Sendable {
    var isVisible: Bool
    var selection: SessionSidebarSelection
    var width: Double?
}

struct SessionStatusEntrySnapshot: Codable, Sendable {
    var key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: TimeInterval
}

struct SessionLogEntrySnapshot: Codable, Sendable {
    var message: String
    var level: String
    var source: String?
    var timestamp: TimeInterval
}

struct SessionProgressSnapshot: Codable, Sendable {
    var value: Double
    var label: String?
}

struct SessionGitBranchSnapshot: Codable, Sendable {
    var branch: String
    var isDirty: Bool
}

enum AIAgentType: String, Codable, Sendable {
    case claudeCode = "claude_code"
    case codex = "codex"
}

/// A generic post-restore terminal action. Today this is backed by agent
/// session resume providers, but the workspace/UI layer only depends on this
/// transport object rather than any specific CLI integration.
struct RestoredTerminalActionSnapshot: Codable, Sendable, Equatable {
    var agentType: AIAgentType
    var sessionId: String?
    var workingDirectory: String?
    var projectPath: String?
    var lastSeenActive: TimeInterval

    var isResumable: Bool {
        normalizedSessionId != nil
    }

    var resumeCommand: String? {
        resumeCommand(permissiveModeEnabled: false)
    }

    func resumeCommand(permissiveModeEnabled: Bool) -> String? {
        switch agentType {
        case .claudeCode:
            guard let sessionId = normalizedSessionId else { return nil }
            if permissiveModeEnabled {
                return "claude --dangerously-skip-permissions --resume \(sessionId)"
            }
            return "claude --resume \(sessionId)"
        case .codex:
            guard let sessionId = normalizedSessionId else { return nil }
            if permissiveModeEnabled {
                return "codex --dangerously-bypass-approvals-and-sandbox resume \(sessionId)"
            }
            return "codex resume \(sessionId)"
        }
    }

    private var normalizedSessionId: String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?
}

struct SessionBrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
}

struct SessionMarkdownPanelSnapshot: Codable, Sendable {
    var filePath: String
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?
    var restoredTerminalAction: RestoredTerminalActionSnapshot?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case customTitle
        case directory
        case isPinned
        case isManuallyUnread
        case gitBranch
        case listeningPorts
        case ttyName
        case terminal
        case browser
        case markdown
        case restoredTerminalAction = "aiSession"
    }
}

protocol RestoredTerminalActionProvider {
    static func restoredTerminalAction(
        workspaceId: UUID,
        panelId: UUID,
        processEnv: [String: String],
        fileManager: FileManager
    ) -> RestoredTerminalActionSnapshot?
}

enum RestoredTerminalActionRegistry {
    private static let providers: [RestoredTerminalActionProvider.Type] = [
        ClaudeHookSessionSnapshotStore.self,
        CodexHookSessionSnapshotStore.self
    ]

    static func latestAction(
        workspaceId: UUID,
        panelId: UUID,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> RestoredTerminalActionSnapshot? {
        providers
            .compactMap {
                $0.restoredTerminalAction(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    processEnv: processEnv,
                    fileManager: fileManager
                )
            }
            .max(by: { $0.lastSeenActive < $1.lastSeenActive })
    }
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

enum ClaudeHookSessionSnapshotStore: RestoredTerminalActionProvider {
    private static let defaultStatePath = "~/.cmuxterm/claude-hook-sessions.json"

    static func restoredTerminalAction(
        workspaceId: UUID,
        panelId: UUID,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> RestoredTerminalActionSnapshot? {
        guard let state = loadState(processEnv: processEnv, fileManager: fileManager) else { return nil }

        let workspaceToken = workspaceId.uuidString.lowercased()
        let panelToken = panelId.uuidString.lowercased()

        guard let record = state.sessions.values
            .filter({
                $0.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == workspaceToken &&
                $0.surfaceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == panelToken
            })
            .max(by: { $0.updatedAt < $1.updatedAt }) else {
            return nil
        }

        let workingDirectory = normalizedOptional(record.cwd)

        return RestoredTerminalActionSnapshot(
            agentType: .claudeCode,
            sessionId: normalizedOptional(record.sessionId),
            workingDirectory: workingDirectory,
            projectPath: workingDirectory,
            lastSeenActive: record.updatedAt
        )
    }

    private static func loadState(
        processEnv: [String: String],
        fileManager: FileManager
    ) -> ClaudeHookSessionStoreFile? {
        let path = statePath(processEnv: processEnv)
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard let data = fileManager.contents(atPath: path) else { return nil }
        guard var state = try? JSONDecoder().decode(ClaudeHookSessionStoreFile.self, from: data) else {
            return nil
        }

        let originalCount = state.sessions.count
        state.sessions = state.sessions.filter { _, record in
            isEligibleLiveRecord(record)
        }

        let removedCount = originalCount - state.sessions.count
        if removedCount > 0 {
            sentryBreadcrumb(
                "ai.resume.claude.pruned_stale_hook_sessions",
                category: "ai_resume",
                data: [
                    "removedCount": removedCount,
                    "remainingCount": state.sessions.count,
                ]
            )
            saveState(state, to: path)
        }

        return state
    }

    private static func statePath(processEnv: [String: String]) -> String {
        if let overridePath = normalizedOptional(processEnv["CMUX_CLAUDE_HOOK_STATE_PATH"]) {
            return NSString(string: overridePath).expandingTildeInPath
        }
        return NSString(string: defaultStatePath).expandingTildeInPath
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isEligibleLiveRecord(_ record: ClaudeHookSessionRecord) -> Bool {
        guard let pid = record.pid, pid > 0 else { return false }
        return processExists(pid)
    }

    private static func processExists(_ pid: Int) -> Bool {
        errno = 0
        if Darwin.kill(pid_t(pid), 0) == 0 {
            return true
        }
        return POSIXErrorCode(rawValue: errno) != .ESRCH
    }

    private static func saveState(_ state: ClaudeHookSessionStoreFile, to path: String) {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        do {
            try fileManagerCreateDirectoryIfNeeded(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            sentryCaptureWarning(
                "Failed to rewrite pruned Claude hook state",
                category: "ai_resume",
                data: [
                    "path": path,
                    "error": String(describing: error),
                ],
                contextKey: "ai_resume_claude_hook_prune"
            )
        }
    }

    private static func fileManagerCreateDirectoryIfNeeded(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
}

enum CodexHookSessionSnapshotStore: RestoredTerminalActionProvider {
    private static let defaultStatePath = "~/.cmuxterm/codex-hook-sessions.json"

    static func restoredTerminalAction(
        workspaceId: UUID,
        panelId: UUID,
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> RestoredTerminalActionSnapshot? {
        guard let state = loadState(processEnv: processEnv, fileManager: fileManager) else { return nil }

        let workspaceToken = workspaceId.uuidString.lowercased()
        let panelToken = panelId.uuidString.lowercased()

        guard let record = state.sessions.values
            .filter({
                $0.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == workspaceToken &&
                $0.surfaceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == panelToken
            })
            .max(by: { $0.updatedAt < $1.updatedAt }) else {
            return nil
        }

        let workingDirectory = normalizedOptional(record.cwd)

        return RestoredTerminalActionSnapshot(
            agentType: .codex,
            sessionId: normalizedOptional(record.sessionId),
            workingDirectory: workingDirectory,
            projectPath: workingDirectory,
            lastSeenActive: record.updatedAt
        )
    }

    private static func loadState(
        processEnv: [String: String],
        fileManager: FileManager
    ) -> CodexHookSessionStoreFile? {
        let path = statePath(processEnv: processEnv)
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(CodexHookSessionStoreFile.self, from: data)
    }

    private static func statePath(processEnv: [String: String]) -> String {
        if let overridePath = normalizedOptional(processEnv["CMUX_CODEX_HOOK_STATE_PATH"]) {
            return NSString(string: overridePath).expandingTildeInPath
        }
        return NSString(string: defaultStatePath).expandingTildeInPath
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SessionSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

struct SessionPaneLayoutSnapshot: Codable, Sendable {
    var panelIds: [UUID]
    var selectedPanelId: UUID?
}

struct SessionSplitLayoutSnapshot: Codable, Sendable {
    var orientation: SessionSplitOrientation
    var dividerPosition: Double
    var first: SessionWorkspaceLayoutSnapshot
    var second: SessionWorkspaceLayoutSnapshot
}

indirect enum SessionWorkspaceLayoutSnapshot: Codable, Sendable {
    case pane(SessionPaneLayoutSnapshot)
    case split(SessionSplitLayoutSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = .pane(try container.decode(SessionPaneLayoutSnapshot.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(SessionSplitLayoutSnapshot.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported layout node type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

struct SessionWorkspaceSnapshot: Codable, Sendable {
    var processTitle: String
    var customTitle: String?
    var organizationName: String?
    var customColor: String?
    var isPinned: Bool
    var currentDirectory: String
    var focusedPanelId: UUID?
    var layout: SessionWorkspaceLayoutSnapshot
    var panels: [SessionPanelSnapshot]
    var statusEntries: [SessionStatusEntrySnapshot]
    var logEntries: [SessionLogEntrySnapshot]
    var progress: SessionProgressSnapshot?
    var gitBranch: SessionGitBranchSnapshot?
}

struct SessionTabManagerSnapshot: Codable, Sendable {
    var selectedWorkspaceIndex: Int?
    var workspaces: [SessionWorkspaceSnapshot]
}

struct SessionWindowSnapshot: Codable, Sendable {
    var frame: SessionRectSnapshot?
    var display: SessionDisplaySnapshot?
    var tabManager: SessionTabManagerSnapshot
    var sidebar: SessionSidebarSnapshot
}

struct AppSessionSnapshot: Codable, Sendable {
    var version: Int
    var createdAt: TimeInterval
    var windows: [SessionWindowSnapshot]
}

enum SessionPersistenceStore {
    static let maximumBackupSnapshots = 12

    static func load(fileURL: URL? = nil) -> AppSessionSnapshot? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        if let fileSize = snapshotFileSize(at: fileURL),
           fileSize > SessionPersistencePolicy.maxSnapshotBytes {
            sentryBreadcrumb(
                "session.restore.skipped.oversize_snapshot",
                category: "startup",
                data: [
                    "path": fileURL.path,
                    "bytes": fileSize,
                    "maxBytes": SessionPersistencePolicy.maxSnapshotBytes
                ]
            )
            return loadLatestBackupSnapshot(forSnapshotFileURL: fileURL)
        }

        if let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) {
            guard data.count <= SessionPersistencePolicy.maxSnapshotBytes else {
                sentryBreadcrumb(
                    "session.restore.skipped.oversize_snapshot_data",
                    category: "startup",
                    data: [
                        "path": fileURL.path,
                        "bytes": data.count,
                        "maxBytes": SessionPersistencePolicy.maxSnapshotBytes
                    ]
                )
                return loadLatestBackupSnapshot(forSnapshotFileURL: fileURL)
            }
            if let snapshot = validatedSnapshot(from: data) {
                return snapshot
            }
            archiveSnapshotData(data, forSnapshotFileURL: fileURL, reason: "failed-load")
        }
        return loadLatestBackupSnapshot(forSnapshotFileURL: fileURL)
    }

    @discardableResult
    static func save(_ snapshot: AppSessionSnapshot, fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try encodedSnapshotData(snapshot)
            if let existingData = try? Data(contentsOf: fileURL) {
                if existingData == data {
                    return true
                }
                archiveSnapshotData(existingData, forSnapshotFileURL: fileURL, reason: "save")
            }
            try data.write(to: fileURL, options: .atomic)
            pruneBackups(forSnapshotFileURL: fileURL)
            return true
        } catch {
            return false
        }
    }

    private static func encodedSnapshotData(_ snapshot: AppSessionSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func removeSnapshot(fileURL: URL? = nil) {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return }
        try? FileManager.default.removeItem(at: fileURL)
        if let backupDirectory = backupDirectoryURL(forSnapshotFileURL: fileURL) {
            try? FileManager.default.removeItem(at: backupDirectory)
        }
    }

    static func defaultSnapshotFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : Branding.releaseBundleIdentifier
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent(Branding.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("session-\(safeBundleId).json", isDirectory: false)
    }

    static func backupDirectoryURL(forSnapshotFileURL fileURL: URL) -> URL? {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let parent = fileURL.deletingLastPathComponent()
        return parent
            .appendingPathComponent("session-backups", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: true)
    }

    private static func snapshotFileSize(at fileURL: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private static func validatedSnapshot(from data: Data) -> AppSessionSnapshot? {
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(AppSessionSnapshot.self, from: data) else { return nil }
        guard snapshot.version == SessionSnapshotSchema.currentVersion else { return nil }
        guard !snapshot.windows.isEmpty else { return nil }
        return snapshot
    }

    private static func loadLatestBackupSnapshot(forSnapshotFileURL fileURL: URL) -> AppSessionSnapshot? {
        guard let backupDirectory = backupDirectoryURL(forSnapshotFileURL: fileURL) else { return nil }
        guard let backupURLs = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let sortedBackups = backupURLs
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        for backupURL in sortedBackups {
            guard let data = try? Data(contentsOf: backupURL) else { continue }
            if let snapshot = validatedSnapshot(from: data) {
                return snapshot
            }
        }
        return nil
    }

    private static func archiveSnapshotData(
        _ data: Data,
        forSnapshotFileURL fileURL: URL,
        reason: String
    ) {
        guard let backupDirectory = backupDirectoryURL(forSnapshotFileURL: fileURL) else { return }
        do {
            try FileManager.default.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            if latestBackupData(in: backupDirectory) == data {
                return
            }

            let stamp = ISO8601DateFormatter.sessionBackupTimestamp.string(from: Date())
            let backupURL = backupDirectory.appendingPathComponent("\(stamp)-\(reason).json", isDirectory: false)
            try data.write(to: backupURL, options: .atomic)
            pruneBackups(in: backupDirectory)
        } catch {
            return
        }
    }

    private static func latestBackupData(in backupDirectory: URL) -> Data? {
        guard let backupURLs = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let latestBackup = backupURLs
            .filter { $0.pathExtension == "json" }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate < rhsDate
            }

        guard let latestBackup else { return nil }
        return try? Data(contentsOf: latestBackup)
    }

    private static func pruneBackups(forSnapshotFileURL fileURL: URL) {
        guard let backupDirectory = backupDirectoryURL(forSnapshotFileURL: fileURL) else { return }
        pruneBackups(in: backupDirectory)
    }

    private static func pruneBackups(in backupDirectory: URL) {
        guard let backupURLs = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let sortedBackups = backupURLs
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        for staleBackup in sortedBackups.dropFirst(maximumBackupSnapshots) {
            try? FileManager.default.removeItem(at: staleBackup)
        }
    }
}

private extension ISO8601DateFormatter {
    static let sessionBackupTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Workspace Organizations

struct WorkspaceOrganization: Codable, Identifiable {
    var id: UUID
    var name: String
    var savedAt: TimeInterval
    var lastUsedAt: TimeInterval
    var snapshot: SessionWorkspaceSnapshot

    init(name: String, snapshot: SessionWorkspaceSnapshot) {
        self.id = UUID()
        self.name = name
        let now = Date().timeIntervalSinceReferenceDate
        self.savedAt = now
        self.lastUsedAt = now
        self.snapshot = snapshot
    }
}

struct WorkspaceExportEnvelope: Codable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: TimeInterval
    var appVersion: String?
    var organization: WorkspaceOrganization

    init(organization: WorkspaceOrganization, appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.version = Self.currentVersion
        self.exportedAt = Date().timeIntervalSinceReferenceDate
        self.appVersion = appVersion
        self.organization = organization
    }
}

enum WorkspaceImportError: LocalizedError, Equatable {
    case readFailed
    case unsupportedFormat
    case decodeFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .readFailed:
            return String(localized: "organization.error.readFailed", defaultValue: "cmux could not read that organization file.")
        case .unsupportedFormat:
            return String(localized: "organization.error.unsupportedFormat", defaultValue: "That organization file uses an unsupported format.")
        case .decodeFailed:
            return String(localized: "organization.error.decodeFailed", defaultValue: "cmux could not decode that organization file.")
        case .writeFailed:
            return String(localized: "organization.error.writeFailed", defaultValue: "cmux could not write the organization file.")
        }
    }
}

enum WorkspaceOrganizationStore {
    static let maxOrganizations = 100
    private static let directoryName = "workspace-organizations"
    private static let workspaceExportType = UTType(exportedAs: "com.cmux.workspace-export")

    static func directoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appendingPathComponent(Branding.appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func loadAll() -> [WorkspaceOrganization] {
        guard let dir = directoryURL() else { return [] }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> WorkspaceOrganization? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(WorkspaceOrganization.self, from: data)
            }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    @discardableResult
    static func save(_ organization: WorkspaceOrganization) -> Bool {
        guard let dir = directoryURL() else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(organization)
            let fileURL = dir.appendingPathComponent("\(organization.id.uuidString).json")
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func upsertAutomaticSnapshot(name: String, snapshot: SessionWorkspaceSnapshot) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        let normalizedDirectory = snapshot.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = loadAll().first {
            $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame &&
            $0.snapshot.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedDirectory
        }

        let now = Date().timeIntervalSinceReferenceDate
        if var existing {
            existing.name = trimmedName
            existing.savedAt = now
            existing.lastUsedAt = now
            existing.snapshot = snapshot
            return save(existing)
        }

        return save(WorkspaceOrganization(name: trimmedName, snapshot: snapshot))
    }

    static func touchLastUsed(_ organizationId: UUID) {
        guard let dir = directoryURL() else { return }
        let fileURL = dir.appendingPathComponent("\(organizationId.uuidString).json")
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        guard var org = try? decoder.decode(WorkspaceOrganization.self, from: data) else { return }
        org.lastUsedAt = Date().timeIntervalSinceReferenceDate
        save(org)
    }

    static func remove(_ organizationId: UUID) {
        guard let dir = directoryURL() else { return }
        let fileURL = dir.appendingPathComponent("\(organizationId.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func exportWorkspace(_ snapshot: SessionWorkspaceSnapshot, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitizedExportFilename(name)
        panel.allowedContentTypes = [workspaceExportType]
        panel.canCreateDirectories = true
        panel.title = String(localized: "organization.export.title", defaultValue: "Export Organization")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let wrapper = WorkspaceOrganization(name: name, snapshot: snapshot)
        guard let data = try? exportData(for: wrapper) else {
            showImportExportError(title: String(localized: "organization.export.error.title", defaultValue: "Export Failed"), error: .writeFailed)
            return
        }
        do {
            try writeExportData(data, to: url)
        } catch {
            showImportExportError(title: String(localized: "organization.export.error.title", defaultValue: "Export Failed"), error: .writeFailed)
        }
    }

    static func importWorkspace() -> WorkspaceOrganization? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [workspaceExportType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "organization.import.title", defaultValue: "Import Organization")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            showImportExportError(title: String(localized: "organization.import.error.title", defaultValue: "Import Failed"), error: .readFailed)
            return nil
        }
        do {
            return try importOrganization(from: data)
        } catch let importError as WorkspaceImportError {
            showImportExportError(title: String(localized: "organization.import.error.title", defaultValue: "Import Failed"), error: importError)
            return nil
        } catch {
            showImportExportError(title: String(localized: "organization.import.error.title", defaultValue: "Import Failed"), error: .decodeFailed)
            return nil
        }
    }

    static func exportData(for organization: WorkspaceOrganization) throws -> Data {
        let envelope = WorkspaceExportEnvelope(organization: organization)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func writeExportData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static func importOrganization(from url: URL) throws -> WorkspaceOrganization {
        guard let data = try? Data(contentsOf: url) else {
            throw WorkspaceImportError.readFailed
        }
        return try importOrganization(from: data)
    }

    static func importOrganization(from data: Data) throws -> WorkspaceOrganization {
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(WorkspaceExportEnvelope.self, from: data) {
            guard envelope.version == WorkspaceExportEnvelope.currentVersion else {
                throw WorkspaceImportError.unsupportedFormat
            }
            return envelope.organization
        }

        if let organization = try? decoder.decode(WorkspaceOrganization.self, from: data) {
            return organization
        }

        throw WorkspaceImportError.decodeFailed
    }

    private static func sanitizedExportFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
        let basename = trimmed.isEmpty ? fallback : trimmed
        let sanitized = basename.replacingOccurrences(
            of: #"[/:\u{0000}-\u{001F}]"#,
            with: "-",
            options: .regularExpression
        )
        return "\(sanitized).cmuxworkspace"
    }

    private static func showImportExportError(title: String, error: WorkspaceImportError) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.errorDescription ?? ""
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}

enum SessionScrollbackReplayStore {
    static let environmentKey = "CMUX_RESTORE_SCROLLBACK_FILE"
    private static let directoryName = "cmux-session-scrollback"
    private static let ansiEscape = "\u{001B}"
    private static let ansiReset = "\u{001B}[0m"

    static func replayEnvironment(
        for scrollback: String?,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        guard let replayText = normalizedScrollback(scrollback) else { return [:] }
        guard let replayFileURL = writeReplayFile(
            contents: replayText,
            tempDirectory: tempDirectory
        ) else {
            return [:]
        }
        return [environmentKey: replayFileURL.path]
    }

    private static func normalizedScrollback(_ scrollback: String?) -> String? {
        guard let scrollback else { return nil }
        guard scrollback.contains(where: { !$0.isWhitespace }) else { return nil }
        guard let truncated = SessionPersistencePolicy.truncatedScrollback(scrollback) else { return nil }
        return ansiSafeReplayText(truncated)
    }

    /// Preserve ANSI color state safely across replay boundaries.
    private static func ansiSafeReplayText(_ text: String) -> String {
        guard text.contains(ansiEscape) else { return text }
        var output = text
        if !output.hasPrefix(ansiReset) {
            output = ansiReset + output
        }
        if !output.hasSuffix(ansiReset) {
            output += ansiReset
        }
        return output
    }

    private static func writeReplayFile(contents: String, tempDirectory: URL) -> URL? {
        guard let data = contents.data(using: .utf8) else { return nil }
        let directory = tempDirectory.appendingPathComponent(directoryName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let fileURL = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
                .appendingPathExtension("txt")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}
