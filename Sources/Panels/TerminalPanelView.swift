import SwiftUI
import Foundation
import AppKit
import Bonsplit

/// View for rendering a terminal panel
struct TerminalPanelView: View {
    @ObservedObject var panel: TerminalPanel
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void
    let restoredTerminalAction: RestoredTerminalActionSnapshot?
    let onRunRestoredTerminalAction: ((RestoredTerminalActionSnapshot) -> Void)?
    let onDismissRestoredTerminalAction: (() -> Void)?

    var body: some View {
        // Layering contract: terminal find UI is mounted in GhosttySurfaceScrollView (AppKit portal layer)
        // via `searchState`. Rendering `SurfaceSearchOverlay` in this SwiftUI container can hide it.
        GhosttyTerminalView(
            terminalSurface: panel.surface,
            paneId: paneId,
            isActive: isFocused,
            isVisibleInUI: isVisibleInUI,
            portalZPriority: portalPriority,
            showsInactiveOverlay: isSplit && !isFocused,
            showsUnreadNotificationRing: hasUnreadNotification && notificationPaneRingEnabled,
            inactiveOverlayColor: appearance.unfocusedOverlayNSColor,
            inactiveOverlayOpacity: appearance.unfocusedOverlayOpacity,
            searchState: panel.searchState,
            restoredTerminalAction: restoredTerminalAction,
            onRunRestoredTerminalAction: onRunRestoredTerminalAction,
            onDismissRestoredTerminalAction: onDismissRestoredTerminalAction,
            reattachToken: panel.viewReattachToken,
            onFocus: { _ in onFocus() },
            onTriggerFlash: onTriggerFlash
        )
        // Keep the NSViewRepresentable identity stable across bonsplit structural updates.
        // This prevents transient teardown/recreate that can momentarily detach the hosted terminal view.
        .id(panel.id)
        .background(Color.clear)
    }
}

/// Shared appearance settings for panels
struct PanelAppearance {
    let dividerColor: Color
    let unfocusedOverlayNSColor: NSColor
    let unfocusedOverlayOpacity: Double

    static func fromConfig(_ config: GhosttyConfig) -> PanelAppearance {
        PanelAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayNSColor: config.unfocusedSplitOverlayFill,
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
    }
}

struct RestoredTerminalActionBanner: View {
    let action: RestoredTerminalActionSnapshot
    let onRun: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    if let detailText {
                        Text(detailText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                if action.isResumable {
                    Button(action: onRun) {
                        Label {
                            Text(String(localized: "aiSession.banner.resume", defaultValue: "Resume"))
                                .font(.system(size: 11, weight: .semibold))
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                    }
                    .padding(.horizontal, 2)
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .controlSize(.small)
                }

                Button(action: onDismiss) {
                    Text(String(localized: "aiSession.banner.startFresh", defaultValue: "Start Fresh"))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 360, maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accentColor.opacity(0.35), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
    }

    private var iconName: String {
        switch action.agentType {
        case .claudeCode:
            return "brain"
        case .codex:
            return "terminal"
        }
    }

    private var accentColor: Color {
        switch action.agentType {
        case .claudeCode:
            return .orange
        case .codex:
            return .green
        }
    }

    private var title: String {
        switch action.agentType {
        case .claudeCode:
            return String(
                localized: "aiSession.banner.claudeDetected",
                defaultValue: "Claude Code session available"
            )
        case .codex:
            return String(
                localized: "aiSession.banner.codexDetected",
                defaultValue: "Codex session available"
            )
        }
    }

    private var detailText: String? {
        let project = action.projectPath ??
            action.workingDirectory ??
            String(localized: "aiSession.banner.unknownProject", defaultValue: "unknown project")
        if let sessionId = action.sessionId {
            let shortId = String(sessionId.prefix(8))
            return String(
                format: String(
                    localized: "aiSession.banner.detailWithSession",
                    defaultValue: "Session %@... - %@"
                ),
                locale: Locale.current,
                shortId,
                project
            )
        }
        return project
    }
}
