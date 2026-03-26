import Foundation

extension CMUXCLI {
    func atlasUsageLines(indentation: String = "          ") -> String {
        [
            "\(indentation)codex <install-hooks|uninstall-hooks>",
            "\(indentation)claude-hook <session-start|stop|notification> [--workspace <id|ref>] [--surface <id|ref>]",
            "\(indentation)codex-hook <session-start|prompt-submit|stop> [--workspace <id|ref>] [--surface <id|ref>]",
        ].joined(separator: "\n")
    }

    func atlasSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "codex":
            return """
            Usage: cmux codex <install-hooks|uninstall-hooks> [--yes]

            Manage Codex CLI hooks integration.

            Subcommands:
              install-hooks     Install cmux hooks into ~/.codex/hooks.json
              uninstall-hooks   Remove cmux hooks from ~/.codex/hooks.json

            Flags:
              --yes, -y         Apply changes without interactive confirmation
            """
        case "claude-hook":
            return """
            Usage: cmux claude-hook <session-start|active|stop|idle|notification|notify|prompt-submit> [flags]

            Hook for Claude Code integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Claude session has started
              active          Alias for session-start
              stop            Signal that a Claude session has stopped
              idle            Alias for stop
              notification    Forward a Claude notification
              notify          Alias for notification
              prompt-submit   Clear notification and set Running on user prompt

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | cmux claude-hook session-start
              echo '{}' | cmux claude-hook stop
            """
        case "codex-hook":
            return """
            Usage: cmux codex-hook <session-start|prompt-submit|stop> [flags]

            Hook for Codex integration. Reads JSON from stdin.

            Subcommands:
              session-start   Signal that a Codex session has started or resumed
              prompt-submit   Set Running status on user prompt
              stop            Signal that a Codex turn has stopped

            Flags:
              --workspace <id|ref>   Target workspace (default: $CMUX_WORKSPACE_ID)
              --surface <id|ref>     Target surface (default: $CMUX_SURFACE_ID)

            Example:
              echo '{"session_id":"abc"}' | cmux codex-hook session-start
              echo '{"session_id":"abc"}' | cmux codex-hook stop
            """
        default:
            return nil
        }
    }

    func runAtlasConnectedCommandIfHandled(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) throws -> Bool {
        switch command {
        case "claude-hook":
            telemetry.breadcrumb("claude-hook.dispatch")
            do {
                try runClaudeHook(commandArgs: commandArgs, client: client, telemetry: telemetry)
                telemetry.breadcrumb("claude-hook.completed")
            } catch {
                telemetry.breadcrumb("claude-hook.failure")
                telemetry.captureError(stage: "claude_hook_dispatch", error: error)
                throw error
            }
            return true

        case "codex-hook":
            telemetry.breadcrumb("codex-hook.dispatch")
            do {
                try runCodexHook(commandArgs: commandArgs, client: client, telemetry: telemetry)
                telemetry.breadcrumb("codex-hook.completed")
            } catch {
                telemetry.breadcrumb("codex-hook.failure")
                telemetry.captureError(stage: "codex_hook_dispatch", error: error)
                throw error
            }
            return true

        default:
            return false
        }
    }
}
