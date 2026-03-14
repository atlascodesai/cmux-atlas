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

    static let shared = EditorSyncController()

    // MARK: - Settings Keys

    static let enabledKey = "editorSync.enabled"
    static let targetEditorKey = "editorSync.targetEditor"

    // MARK: - Published State

    /// Whether editor sync is active.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    /// The editor to open on workspace switch.
    @Published var targetEditor: TerminalDirectoryOpenTarget {
        didSet {
            UserDefaults.standard.set(targetEditor.rawValue, forKey: Self.targetEditorKey)
        }
    }

    // MARK: - Internal State

    /// The last directory we opened in the editor, to avoid re-opening the same one.
    private var lastOpenedDirectory: String?

    /// Debounce timer for rapid workspace switching.
    private var debounceTask: Task<Void, Never>?

    /// Delay before triggering editor open (allows rapid tab switching to settle).
    private let debounceInterval: Duration = .milliseconds(300)

    /// Hook for getting the current workspace directory. Set by TabManager.
    var currentWorkspaceDirectory: () -> String? = { nil }

    // MARK: - Init

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        if let raw = UserDefaults.standard.string(forKey: Self.targetEditorKey),
           let target = TerminalDirectoryOpenTarget(rawValue: raw) {
            self.targetEditor = target
        } else {
            // Auto-detect: prefer Cursor, fall back to VS Code
            if TerminalDirectoryOpenTarget.cursor.applicationURL() != nil {
                self.targetEditor = .cursor
            } else if TerminalDirectoryOpenTarget.vscode.applicationURL() != nil {
                self.targetEditor = .vscode
            } else if TerminalDirectoryOpenTarget.zed.applicationURL() != nil {
                self.targetEditor = .zed
            } else if TerminalDirectoryOpenTarget.windsurf.applicationURL() != nil {
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
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(300))
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
        switch editor {
        case .cursor:
            // Cursor CLI: same flags as VS Code
            if let cli = findCLI(names: ["cursor"]) {
                return [cli, "--reuse-window", directory]
            }
            // Cursor sometimes installs as 'code' in its own path
            if let appURL = editor.applicationURL() {
                let embeddedCLI = appURL.path + "/Contents/Resources/app/bin/code"
                if FileManager.default.isExecutableFile(atPath: embeddedCLI) {
                    return [embeddedCLI, "--reuse-window", directory]
                }
            }
            return nil

        case .vscode:
            if let cli = findCLI(names: ["code"]) {
                return [cli, "--reuse-window", directory]
            }
            if let appURL = editor.applicationURL() {
                let embeddedCLI = appURL.path + "/Contents/Resources/app/bin/code"
                if FileManager.default.isExecutableFile(atPath: embeddedCLI) {
                    return [embeddedCLI, "--reuse-window", directory]
                }
            }
            return nil

        case .windsurf:
            if let cli = findCLI(names: ["windsurf"]) {
                return [cli, "--reuse-window", directory]
            }
            return nil

        case .zed:
            // Zed reuses the existing window by default
            if let cli = findCLI(names: ["zed"]) {
                return [cli, directory]
            }
            return nil

        case .xcode:
            // xed opens in Xcode; no --reuse-window but it reuses by default
            return ["/usr/bin/xed", directory]

        default:
            return nil
        }
    }

    /// Searches PATH for a CLI binary by name.
    private func findCLI(names: [String]) -> String? {
        let searchPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/bin",
        ]

        for name in names {
            for dir in searchPaths {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    /// Launches a CLI command in the background without blocking.
    private func launchCLI(_ arguments: [String]) {
        guard let executable = arguments.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Inherit a clean environment but ensure PATH is set
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/usr/local/bin:/opt/homebrew/bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = extraPaths + ":" + existingPath
        } else {
            env["PATH"] = extraPaths + ":/usr/bin:/bin"
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            // Silently ignore — editor may not be available
        }
    }

    /// Fallback: use NSWorkspace.open for editors without CLI support.
    private func fallbackOpen(directory: String) {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard let applicationURL = targetEditor.applicationURL() else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        NSWorkspace.shared.open(
            [directoryURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
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
