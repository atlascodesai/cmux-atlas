import SwiftUI

enum AIQuickLaunchAgent {
    case codex
    case claudeCode
}

enum AIQuickLaunchStrings {
    static func accessibilityLabel(for agent: AIQuickLaunchAgent) -> String {
        switch agent {
        case .codex:
            return String(localized: "aiQuickLaunch.codex.accessibility", defaultValue: "Open Codex")
        case .claudeCode:
            return String(localized: "aiQuickLaunch.claude.accessibility", defaultValue: "Open Claude Code")
        }
    }

    static func helpText(for agent: AIQuickLaunchAgent, permissiveEnabled: Bool) -> String {
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

    static func permissiveToggleTitle(for agent: AIQuickLaunchAgent, permissiveEnabled: Bool) -> String {
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
            BrowserLinkToggleTitlebarButton(config: config)
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
        AIQuickLaunchStrings.accessibilityLabel(for: agent)
    }

    private var helpText: String {
        AIQuickLaunchStrings.helpText(for: agent, permissiveEnabled: permissiveEnabled)
    }

    private var permissiveToggleTitle: String {
        AIQuickLaunchStrings.permissiveToggleTitle(for: agent, permissiveEnabled: permissiveEnabled)
    }
}
