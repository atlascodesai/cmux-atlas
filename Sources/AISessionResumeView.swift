import Foundation
import SwiftUI

/// Banner shown at the top of a restored terminal when an AI agent session
/// was detected at the time of the previous snapshot. Offers one-click resume.
struct AISessionResumeBanner: View {
    let session: AISessionSnapshot
    let onResume: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if let detail = detailText {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if session.resumeCommand != nil {
                Button(action: onResume) {
                    Label {
                        Text(String(localized: "aiSession.banner.resume", defaultValue: "Resume"))
                            .font(.system(size: 11, weight: .medium))
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .controlSize(.small)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(accentColor.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accentColor.opacity(0.3), lineWidth: 1)
                }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var iconName: String {
        switch session.agentType {
        case .claudeCode:
            return "brain"
        case .codex:
            return "terminal"
        }
    }

    private var accentColor: Color {
        switch session.agentType {
        case .claudeCode:
            return .orange
        case .codex:
            return .green
        }
    }

    private var title: String {
        switch session.agentType {
        case .claudeCode:
            return String(
                localized: "aiSession.banner.claudeDetected",
                defaultValue: "Claude Code session detected"
            )
        case .codex:
            return String(
                localized: "aiSession.banner.codexDetected",
                defaultValue: "Codex session detected"
            )
        }
    }

    private var detailText: String? {
        let project = session.projectPath ??
            session.workingDirectory ??
            String(localized: "aiSession.banner.unknownProject", defaultValue: "unknown project")
        if let sessionId = session.sessionId {
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
