import AppKit
import Combine
import Foundation

/// Automatically opens the selected workspace's directory in an external editor
/// (VS Code, Cursor, etc.) whenever the user switches workspaces in cmux.
///
/// When enabled, switching to a workspace triggers the configured editor to open
/// that workspace's `currentDirectory`. This gives a two-window workflow:
/// cmux on the left, editor on the right — clicking a workspace in cmux instantly
/// shows the matching project in the editor.
///
/// Uses CLI commands with --reuse-window so only one editor window is open at a time.
/// Switching workspaces in cmux changes the project in the same editor window.
///
/// Behavior:
/// - Single window: reuses the same editor window instead of opening new ones
/// - Debounced: rapid workspace switching only triggers one editor open (300ms)
/// - Deduplicates: won't re-open the same directory if it's already the active one
/// - Configurable: target editor stored in UserDefaults
/// - Non-blocking: editor open is async and failures are silently ignored
@MainActor
final class EditorSyncController: ObservableObject {
    struct Environment {
        var homeDirectoryPath: String
        var isExecutableFileAtPath: (String) -> Bool
        var applicationURLForTarget: (TerminalDirectoryOpenTarget) -> URL?
        var bundleIdentifierForTarget: (TerminalDirectoryOpenTarget) -> String?
        var isApplicationRunning: (String) -> Bool
        var inheritedEnvironment: () -> [String: String]
        var sleep: (Duration) async -> Void
        var runCLI: (URL, [String], [String: String]) throws -> Void
        var openDirectory: (URL, URL) -> Void

        static let live = Environment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutableFileAtPath: { FileManager.default.isExecutableFile(atPath: $0) },
            applicationURLForTarget: { $0.applicationURL() },
            bundleIdentifierForTarget: { target in
                target.applicationURL().flatMap { Bundle(url: $0)?.bundleIdentifier }
            },
            isApplicationRunning: { bundleIdentifier in
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
            },
            inheritedEnvironment: { ProcessInfo.processInfo.environment },
            sleep: { duration in
                try? await Task.sleep(for: duration)
            },
            runCLI: { executableURL, arguments, environment in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.environment = environment
                try process.run()
            },
            openDirectory: { directoryURL, applicationURL in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.open(
                    [directoryURL],
                    withApplicationAt: applicationURL,
                    configuration: configuration
                )
            }
        )
    }

    static let shared = EditorSyncController()

    // MARK: - Settings Keys

    static let enabledKey = "editorSync.enabled"
    static let targetEditorKey = "editorSync.targetEditor"

    private let defaults: UserDefaults
    private let environment: Environment

    // MARK: - Published State

    /// Whether editor sync is active.
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    /// The editor to open on workspace switch.
    @Published var targetEditor: TerminalDirectoryOpenTarget {
        didSet {
            defaults.set(targetEditor.rawValue, forKey: Self.targetEditorKey)
        }
    }

    // MARK: - Internal State

    /// The last directory we opened in the editor, to avoid re-opening the same one.
    private var lastOpenedDirectory: String?

    /// Debounce timer for rapid workspace switching.
    private var debounceTask: Task<Void, Never>?

    /// Delay before triggering editor open (allows rapid tab switching to settle).
    private let debounceInterval: Duration

    /// Hook for getting the current workspace directory. Set by TabManager.
    var currentWorkspaceDirectory: () -> String? = { nil }

    // MARK: - Init

    private convenience init() {
        self.init(defaults: .standard, environment: .live, debounceInterval: .milliseconds(300))
    }

    init(
        defaults: UserDefaults = .standard,
        environment: Environment = .live,
        debounceInterval: Duration = .milliseconds(300)
    ) {
        self.defaults = defaults
        self.environment = environment
        self.debounceInterval = debounceInterval
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)

        if let raw = defaults.string(forKey: Self.targetEditorKey),
           let target = TerminalDirectoryOpenTarget(rawValue: raw) {
            self.targetEditor = target
        } else {
            // Auto-detect: prefer Cursor, fall back to VS Code
            if environment.applicationURLForTarget(.cursor) != nil {
                self.targetEditor = .cursor
            } else if environment.applicationURLForTarget(.vscode) != nil {
                self.targetEditor = .vscode
            } else if environment.applicationURLForTarget(.zed) != nil {
                self.targetEditor = .zed
            } else if environment.applicationURLForTarget(.windsurf) != nil {
                self.targetEditor = .windsurf
            } else {
                self.targetEditor = .vscode
            }
        }
    }

    // MARK: - Workspace Switch Handler

    /// Called when the selected workspace changes. Opens the workspace's directory
    /// in the configured editor after a debounce delay.
    func workspaceDidChange(directory: String?) {
        guard isEnabled else { return }
        guard let directory, !directory.isEmpty else { return }

        // Cancel any pending debounce
        debounceTask?.cancel()

        debounceTask = Task { [weak self] in
            await self?.environment.sleep(self?.debounceInterval ?? .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.openDirectoryInEditor(directory)
        }
    }

    /// Opens the current workspace directory immediately (e.g. when the user first enables sync).
    func openCurrentDirectoryNow(activate: Bool = true) {
        guard let directory = currentWorkspaceDirectory(), !directory.isEmpty else { return }
        lastOpenedDirectory = nil  // Force re-open even if same directory
        openDirectoryInEditor(directory)
    }

    @discardableResult
    func openFileInEditorIfRunning(
        _ path: String,
        line: Int? = nil,
        column: Int? = nil
    ) -> Bool {
        guard isEnabled, isTargetEditorRunning() else { return false }
        guard let cliArgs = fileCLICommand(for: targetEditor, path: path, line: line, column: column) else {
            return false
        }
        launchCLI(cliArgs)
        return true
    }

    func isTargetEditorRunning() -> Bool {
        guard let bundleIdentifier = environment.bundleIdentifierForTarget(targetEditor),
              !bundleIdentifier.isEmpty else {
            return false
        }
        return environment.isApplicationRunning(bundleIdentifier)
    }

    // MARK: - Editor Open (CLI-based, single window)

    /// Opens a directory in the configured external editor, reusing the existing window.
    private func openDirectoryInEditor(_ directory: String) {
        // Don't re-open if it's the same directory
        guard directory != lastOpenedDirectory else { return }
        lastOpenedDirectory = directory

        // Use CLI commands with --reuse-window to keep a single editor window
        if let cliArgs = cliCommand(for: targetEditor, directory: directory) {
            launchCLI(cliArgs)
        } else {
            // Fallback: NSWorkspace.open for editors without a known CLI
            fallbackOpen(directory: directory)
        }
    }

    /// Returns the CLI command + arguments to open a directory in the editor,
    /// reusing the existing window. Returns nil if no CLI is known for this editor.
    private func cliCommand(for editor: TerminalDirectoryOpenTarget, directory: String) -> [String]? {
        guard let executable = cliExecutable(for: editor) else { return nil }
        switch editor {
        case .cursor, .vscode, .windsurf:
            return [executable, "--reuse-window", directory]
        case .zed:
            return [executable, "--reuse", directory]
        case .xcode:
            return [executable, directory]
        default:
            return nil
        }
    }

    private func fileCLICommand(
        for editor: TerminalDirectoryOpenTarget,
        path: String,
        line: Int?,
        column: Int?
    ) -> [String]? {
        guard let executable = cliExecutable(for: editor) else { return nil }
        let positionedPath: String = {
            guard let line else { return path }
            guard let column else { return "\(path):\(line)" }
            return "\(path):\(line):\(column)"
        }()

        switch editor {
        case .cursor, .vscode, .windsurf:
            if line != nil {
                return [executable, "--reuse-window", "--goto", positionedPath]
            }
            return [executable, "--reuse-window", path]
        case .zed:
            return [executable, "--reuse", positionedPath]
        case .xcode:
            if let line {
                return [executable, "--line", "\(line)", path]
            }
            return [executable, path]
        default:
            return nil
        }
    }

    private func cliExecutable(for editor: TerminalDirectoryOpenTarget) -> String? {
        switch editor {
        case .cursor:
            if let cli = findCLI(names: ["cursor"]) {
                return cli
            }
            if let appURL = environment.applicationURLForTarget(editor) {
                let embeddedCLI = appURL.path + "/Contents/Resources/app/bin/code"
                if environment.isExecutableFileAtPath(embeddedCLI) {
                    return embeddedCLI
                }
            }
            return nil

        case .vscode:
            if let cli = findCLI(names: ["code"]) {
                return cli
            }
            if let appURL = environment.applicationURLForTarget(editor) {
                let embeddedCLI = appURL.path + "/Contents/Resources/app/bin/code"
                if environment.isExecutableFileAtPath(embeddedCLI) {
                    return embeddedCLI
                }
            }
            return nil

        case .windsurf:
            return findCLI(names: ["windsurf"])

        case .zed:
            if let cli = findCLI(names: ["zed"]) {
                return cli
            }
            if let appURL = environment.applicationURLForTarget(editor) {
                let embeddedCLI = appURL.path + "/Contents/MacOS/cli"
                if environment.isExecutableFileAtPath(embeddedCLI) {
                    return embeddedCLI
                }
            }
            return nil

        case .xcode:
            return "/usr/bin/xed"

        default:
            return nil
        }
    }

    /// Searches PATH for a CLI binary by name.
    private func findCLI(names: [String]) -> String? {
        let searchPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            environment.homeDirectoryPath + "/.local/bin",
            environment.homeDirectoryPath + "/bin",
        ]

        for name in names {
            for dir in searchPaths {
                let path = "\(dir)/\(name)"
                if environment.isExecutableFileAtPath(path) {
                    return path
                }
            }
        }
        return nil
    }

    /// Launches a CLI command in the background without blocking.
    private func launchCLI(_ arguments: [String]) {
        guard let executable = arguments.first else { return }

        // Inherit a clean environment but ensure PATH is set
        var env = environment.inheritedEnvironment()
        let extraPaths = "/usr/local/bin:/opt/homebrew/bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = extraPaths + ":" + existingPath
        } else {
            env["PATH"] = extraPaths + ":/usr/bin:/bin"
        }

        do {
            try environment.runCLI(
                URL(fileURLWithPath: executable),
                Array(arguments.dropFirst()),
                env
            )
        } catch {
            // Silently ignore — editor may not be available
        }
    }

    /// Fallback: use NSWorkspace.open for editors without CLI support.
    private func fallbackOpen(directory: String) {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard let applicationURL = environment.applicationURLForTarget(targetEditor) else { return }
        environment.openDirectory(directoryURL, applicationURL)
    }

    // MARK: - Available Editors

    /// Returns editors that are actually installed on this machine.
    static var availableEditors: [TerminalDirectoryOpenTarget] {
        let editorTargets: [TerminalDirectoryOpenTarget] = [
            .cursor, .vscode, .windsurf, .zed, .xcode, .androidStudio, .antigravity
        ]
        return editorTargets.filter { $0.applicationURL() != nil }
    }
}
