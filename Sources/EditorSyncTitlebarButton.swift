import SwiftUI

enum AIQuickLaunchAgent {
    case codex
    case claudeCode
}

@MainActor
final class AIQuickLaunchController: ObservableObject {
    static let shared = AIQuickLaunchController()

    private static let codexPermissiveKey = "aiQuickLaunch.codexPermissive"
    private static let claudePermissiveKey = "aiQuickLaunch.claudePermissive"

    @Published var codexPermissiveMode: Bool {
        didSet {
            UserDefaults.standard.set(codexPermissiveMode, forKey: Self.codexPermissiveKey)
        }
    }

    @Published var claudePermissiveMode: Bool {
        didSet {
            UserDefaults.standard.set(claudePermissiveMode, forKey: Self.claudePermissiveKey)
        }
    }

    private init() {
        codexPermissiveMode = UserDefaults.standard.bool(forKey: Self.codexPermissiveKey)
        claudePermissiveMode = UserDefaults.standard.bool(forKey: Self.claudePermissiveKey)
    }

    func command(for agent: AIQuickLaunchAgent) -> String {
        switch agent {
        case .codex:
            return codexPermissiveMode ? "codex --yolo" : "codex"
        case .claudeCode:
            return claudePermissiveMode ? "claude --dangerously-skip-permissions" : "claude"
        }
    }

    func permissiveModeEnabled(for agent: AIQuickLaunchAgent) -> Bool {
        switch agent {
        case .codex:
            return codexPermissiveMode
        case .claudeCode:
            return claudePermissiveMode
        }
    }

    func togglePermissiveMode(for agent: AIQuickLaunchAgent) {
        switch agent {
        case .codex:
            codexPermissiveMode.toggle()
        case .claudeCode:
            claudePermissiveMode.toggle()
        }
    }
}

struct WorkspaceTabBarLeadingButtons: View {
    let config: TitlebarControlsStyleConfig?
    let launchAgent: (AIQuickLaunchAgent) -> Void

    private var spacing: CGFloat { config?.spacing ?? 6 }

    var body: some View {
        HStack(spacing: spacing) {
            AIQuickLaunchTitlebarButton(
                agent: .codex,
                config: config,
                launch: { launchAgent(.codex) }
            )
            AIQuickLaunchTitlebarButton(
                agent: .claudeCode,
                config: config,
                launch: { launchAgent(.claudeCode) }
            )
            EditorSyncTitlebarButton(config: config)
        }
    }
}

struct AIQuickLaunchTitlebarButton: View {
    let agent: AIQuickLaunchAgent
    let config: TitlebarControlsStyleConfig?
    let launch: () -> Void

    @ObservedObject private var quickLaunch = AIQuickLaunchController.shared

    private var iconSize: CGFloat { config?.iconSize ?? 12 }
    private var buttonSize: CGFloat? { config?.buttonSize }
    private var permissiveEnabled: Bool { quickLaunch.permissiveModeEnabled(for: agent) }

    var body: some View {
        let button = Button(action: launch) {
            Image(imageName)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Toggle(permissiveToggleTitle, isOn: Binding(
                get: { permissiveEnabled },
                set: { _ in quickLaunch.togglePermissiveMode(for: agent) }
            ))
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .help(helpText)

        if let buttonSize {
            button.frame(width: buttonSize, height: buttonSize)
        } else {
            button
        }
    }

    private var imageName: String {
        switch agent {
        case .codex:
            return "codex-logo"
        case .claudeCode:
            return "claude-logo"
        }
    }

    private var accessibilityIdentifier: String {
        switch agent {
        case .codex:
            return "titlebarControl.quickLaunch.codex"
        case .claudeCode:
            return "titlebarControl.quickLaunch.claude"
        }
    }

    private var accessibilityLabel: String {
        switch agent {
        case .codex:
            return String(localized: "aiQuickLaunch.codex.accessibility", defaultValue: "Open Codex")
        case .claudeCode:
            return String(localized: "aiQuickLaunch.claude.accessibility", defaultValue: "Open Claude Code")
        }
    }

    private var helpText: String {
        switch agent {
        case .codex:
            return permissiveEnabled
                ? String(
                    localized: "aiQuickLaunch.codex.help.enabled",
                    defaultValue: "Open Codex (--yolo enabled)"
                )
                : String(
                    localized: "aiQuickLaunch.codex.help.disabled",
                    defaultValue: "Open Codex"
                )
        case .claudeCode:
            return permissiveEnabled
                ? String(
                    localized: "aiQuickLaunch.claude.help.enabled",
                    defaultValue: "Open Claude Code (--dangerously-skip-permissions enabled)"
                )
                : String(
                    localized: "aiQuickLaunch.claude.help.disabled",
                    defaultValue: "Open Claude Code"
                )
        }
    }

    private var permissiveToggleTitle: String {
        switch agent {
        case .codex:
            return permissiveEnabled
                ? String(
                    localized: "aiQuickLaunch.codex.context.disablePermissive",
                    defaultValue: "Disable --yolo"
                )
                : String(
                    localized: "aiQuickLaunch.codex.context.enablePermissive",
                    defaultValue: "Enable --yolo"
                )
        case .claudeCode:
            return permissiveEnabled
                ? String(
                    localized: "aiQuickLaunch.claude.context.disablePermissive",
                    defaultValue: "Disable --dangerously-skip-permissions"
                )
                : String(
                    localized: "aiQuickLaunch.claude.context.enablePermissive",
                    defaultValue: "Enable --dangerously-skip-permissions"
                )
        }
    }
}

/// Tab bar button for editor sync. Left-click toggles sync on/off.
/// Right-click shows a picker to choose the target editor.
///
/// Shortcuts:
/// - ⌘E        → Toggle sync on/off (shows picker if first time)
/// - ⌘E, 1-9   → Pick editor by number (opens popover, press number)
struct EditorSyncTitlebarButton: View {
    /// When nil, uses tab-bar-native styling (12pt icon, no frame constraints).
    let config: TitlebarControlsStyleConfig?
    @ObservedObject private var editorSync = EditorSyncController.shared
    @State private var isHovering = false
    @State private var showingPicker = false

    private var availableEditors: [TerminalDirectoryOpenTarget] {
        EditorSyncController.availableEditors
    }

    private var iconSize: CGFloat { config?.iconSize ?? 12 }
    private var buttonSize: CGFloat? { config?.buttonSize }

    var body: some View {
        let button = Button {
            if editorSync.isEnabled {
                editorSync.isEnabled = false
            } else if availableEditors.isEmpty {
                // No editors installed
            } else {
                showingPicker = true
            }
        } label: {
            ZStack {
                Image(systemName: editorSync.isEnabled ? "curlybraces.square.fill" : "curlybraces.square")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(editorSync.isEnabled ? AnyShapeStyle(cmuxAccentColor()) : AnyShapeStyle(.primary))
                    .frame(width: buttonSize, height: buttonSize)

                if editorSync.isEnabled {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .offset(
                            x: (buttonSize ?? 20) / 2 - 4,
                            y: -((buttonSize ?? 20) / 2 - 4)
                        )
                }
            }
        }
        .buttonStyle(config != nil ? .plain : .plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            editorPickerPopover
        }
        .contextMenu {
            editorContextMenu
        }
        .accessibilityIdentifier("titlebarControl.editorSync")
        .accessibilityLabel("Editor Sync")
        .help(editorSync.isEnabled
            ? "Editor sync: \(editorDisplayName(editorSync.targetEditor)) (⌘E to toggle)"
            : "Link an editor (⌘E)")
        .keyboardShortcut("e", modifiers: .command)

        if let buttonSize {
            button.frame(width: buttonSize, height: buttonSize)
        } else {
            button
        }
    }

    // MARK: - Popover Picker (shown on first click or when disabled)

    private var editorPickerPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Link Editor  ⌘E")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)

            Divider()

            ForEach(Array(availableEditors.enumerated()), id: \.element.rawValue) { index, editor in
                let number = index + 1
                Button {
                    selectEditor(editor)
                } label: {
                    HStack(spacing: 8) {
                        // Number badge
                        Text("\(number)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)

                        editorIcon(for: editor)
                            .frame(width: 16, height: 16)

                        Text(editorDisplayName(editor))
                            .font(.system(size: 12))

                        Spacer()

                        if editor == editorSync.targetEditor && editorSync.isEnabled {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(cmuxAccentColor())
                        }

                        // Shortcut hint
                        Text("⌘E \(number)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Number key shortcut within the popover
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
            }

            if availableEditors.isEmpty {
                Text("No supported editors installed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

            if editorSync.isEnabled {
                Divider()
                Button {
                    editorSync.isEnabled = false
                    showingPicker = false
                } label: {
                    HStack {
                        Text("Disable Sync")
                            .font(.system(size: 12))
                        Spacer()
                        Text("⌘E")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 200)
    }

    // MARK: - Context Menu (right-click)

    @ViewBuilder
    private var editorContextMenu: some View {
        ForEach(Array(availableEditors.enumerated()), id: \.element.rawValue) { index, editor in
            Button {
                selectEditor(editor)
            } label: {
                HStack {
                    Text("\(index + 1). \(editorDisplayName(editor))")
                    if editor == editorSync.targetEditor && editorSync.isEnabled {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }

        if editorSync.isEnabled {
            Divider()
            Button("Disable Editor Sync") {
                editorSync.isEnabled = false
            }
        }
    }

    // MARK: - Actions

    private func selectEditor(_ editor: TerminalDirectoryOpenTarget) {
        editorSync.targetEditor = editor
        editorSync.isEnabled = true
        showingPicker = false
        editorSync.openCurrentDirectoryNow(activate: true)
    }

    // MARK: - Helpers

    private func editorDisplayName(_ editor: TerminalDirectoryOpenTarget) -> String {
        switch editor {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        case .androidStudio: return "Android Studio"
        case .antigravity: return "Antigravity"
        default: return editor.rawValue.capitalized
        }
    }

    private func editorIcon(for editor: TerminalDirectoryOpenTarget) -> some View {
        let symbolName: String
        switch editor {
        case .cursor: symbolName = "cursorarrow.rays"
        case .vscode: symbolName = "chevron.left.forwardslash.chevron.right"
        case .windsurf: symbolName = "wind"
        case .zed: symbolName = "bolt.fill"
        case .xcode: symbolName = "hammer.fill"
        case .androidStudio: symbolName = "ant.fill"
        default: symbolName = "app.fill"
        }
        return Image(systemName: symbolName)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
    }
}

// MARK: - Browser Link Toggle Context Menu

struct BrowserLinkToggleContextMenu: View {
    @AppStorage(BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
    private var openLinksInternally = BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser

    var body: some View {
        Toggle(
            String(localized: "browser.linkToggle.internal", defaultValue: "Open Links in cmux Browser"),
            isOn: $openLinksInternally
        )
    }
}
