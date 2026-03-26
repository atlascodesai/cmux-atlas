import Foundation

extension CMUXCLI {
    func runAtlasStandaloneCommandIfHandled(command: String, commandArgs: [String]) throws -> Bool {
        switch command {
        case "codex":
            try runCodexManagementCommand(commandArgs: commandArgs)
            return true
        default:
            return false
        }
    }

    private func runCodexManagementCommand(commandArgs: [String]) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"

        switch subcommand {
        case "install-hooks":
            try runCodexInstallHooks(commandArgs: Array(commandArgs.dropFirst()))
        case "uninstall-hooks":
            try runCodexUninstallHooks(commandArgs: Array(commandArgs.dropFirst()))
        case "help", "--help", "-h":
            print(atlasSubcommandUsage("codex") ?? "Usage: cmux codex <install-hooks|uninstall-hooks>")
        default:
            throw CLIError(message: "Unknown codex subcommand: \(subcommand)")
        }
    }

    private static func codexHookCommand(_ event: String) -> String {
        "[ -n \"$CMUX_SURFACE_ID\" ] && command -v cmux >/dev/null 2>&1 && cmux codex-hook \(event) || echo '{}'"
    }

    private static let codexHooksJSON: [String: Any] = [
        "hooks": [
            "SessionStart": [[
                "hooks": [[
                    "type": "command",
                    "command": codexHookCommand("session-start"),
                    "timeout": 10
                ] as [String: Any]]
            ] as [String: Any]],
            "UserPromptSubmit": [[
                "hooks": [[
                    "type": "command",
                    "command": codexHookCommand("prompt-submit"),
                    "timeout": 10
                ] as [String: Any]]
            ] as [String: Any]],
            "Stop": [[
                "hooks": [[
                    "type": "command",
                    "command": codexHookCommand("stop"),
                    "timeout": 10
                ] as [String: Any]]
            ] as [String: Any]]
        ] as [String: Any]
    ]

    private static let codexHookCommandMarker = "cmux codex-hook"

    private func runCodexInstallHooks(commandArgs: [String]) throws {
        let skipConfirm = commandArgs.contains("--yes") || commandArgs.contains("-y")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        let hooksPath = (codexHome as NSString).appendingPathComponent("hooks.json")
        let configPath = (codexHome as NSString).appendingPathComponent("config.toml")
        let fileManager = FileManager.default

        try fileManager.createDirectory(atPath: codexHome, withIntermediateDirectories: true, attributes: nil)

        let existingHooksContent: String? = fileManager.fileExists(atPath: hooksPath)
            ? (try? String(contentsOfFile: hooksPath, encoding: .utf8))
            : nil

        var existingHooksRoot: [String: Any] = [:]
        if let existingHooksContent,
           let data = existingHooksContent.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existingHooksRoot = parsed
        }

        var hooks = existingHooksRoot["hooks"] as? [String: Any] ?? [:]
        let cmuxHooks = Self.codexHooksJSON["hooks"] as? [String: Any] ?? [:]
        for (eventName, cmuxGroups) in cmuxHooks {
            guard let cmuxGroupArray = cmuxGroups as? [[String: Any]] else { continue }
            var eventGroups = hooks[eventName] as? [[String: Any]] ?? []
            eventGroups.removeAll { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                return groupHooks.allSatisfy { hook in
                    (hook["command"] as? String)?.contains(Self.codexHookCommandMarker) == true
                }
            }
            eventGroups.append(contentsOf: cmuxGroupArray)
            hooks[eventName] = eventGroups
        }
        existingHooksRoot["hooks"] = hooks

        let newJSONData = try JSONSerialization.data(withJSONObject: existingHooksRoot, options: [.prettyPrinted, .sortedKeys])
        let newHooksContent = String(data: newJSONData, encoding: .utf8) ?? ""

        let existingConfigContent: String = fileManager.fileExists(atPath: configPath)
            ? ((try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "")
            : ""
        let newConfigContent = buildConfigWithCodexHooks(existingConfigContent)

        let hooksChanged = existingHooksContent != newHooksContent
        let configChanged = existingConfigContent != newConfigContent

        if !hooksChanged && !configChanged {
            print("cmux hooks are already installed. Nothing to change.")
            return
        }

        if hooksChanged {
            print("  \(hooksPath):")
            if let existingHooksContent {
                printSimpleDiff(old: existingHooksContent, new: newHooksContent)
            } else {
                print("    (new file)")
                let lines = newHooksContent.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let lineLabel = String(format: "%3d", index + 1)
                    print("    \u{001B}[32m\(lineLabel) +\(line)\u{001B}[0m")
                }
            }
            print("")
        }

        if configChanged {
            print("  \(configPath):")
            if existingConfigContent.isEmpty {
                print("    (new file)")
                let lines = newConfigContent.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where !line.isEmpty {
                    let lineLabel = String(format: "%3d", index + 1)
                    print("    \u{001B}[32m\(lineLabel) +\(line)\u{001B}[0m")
                }
            } else {
                printSimpleDiff(old: existingConfigContent, new: newConfigContent)
            }
            print("")
        }

        if !skipConfirm {
            print("Apply these changes? [Y/n] ", terminator: "")
            if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !response.isEmpty && response != "y" && response != "yes" {
                print("Aborted.")
                return
            }
        }

        if hooksChanged {
            try newJSONData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)
        }
        if configChanged {
            try newConfigContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        }

        print("")
        print("Installed. Hooks activate inside cmux and silently no-op elsewhere.")
        print("To remove: cmux codex uninstall-hooks")
    }

    private func runCodexUninstallHooks(commandArgs: [String]) throws {
        let skipConfirm = commandArgs.contains("--yes") || commandArgs.contains("-y")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        let hooksPath = (codexHome as NSString).appendingPathComponent("hooks.json")
        let configPath = (codexHome as NSString).appendingPathComponent("config.toml")
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: hooksPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)),
              var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("No hooks.json found at \(hooksPath)")
            return
        }

        guard var hooks = parsed["hooks"] as? [String: Any] else {
            print("No hooks section found in \(hooksPath)")
            return
        }

        var removedCount = 0
        for eventName in hooks.keys {
            guard var eventGroups = hooks[eventName] as? [[String: Any]] else { continue }
            let before = eventGroups.count
            eventGroups.removeAll { group in
                guard let groupHooks = group["hooks"] as? [[String: Any]] else { return false }
                return groupHooks.allSatisfy { hook in
                    (hook["command"] as? String)?.contains(Self.codexHookCommandMarker) == true
                }
            }
            removedCount += before - eventGroups.count
            if eventGroups.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = eventGroups
            }
        }

        let existingConfigContent: String = fileManager.fileExists(atPath: configPath)
            ? ((try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "")
            : ""
        let newConfigContent = buildConfigWithoutCodexHooks(existingConfigContent)
        let configChanged = existingConfigContent != newConfigContent

        if removedCount == 0 && !configChanged {
            print("No cmux hooks found.")
            return
        }

        parsed["hooks"] = hooks
        let newJSONData = try JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys])
        let newHooksContent = String(data: newJSONData, encoding: .utf8) ?? ""
        let oldHooksContent = String(data: data, encoding: .utf8) ?? ""

        if removedCount > 0 {
            print("  \(hooksPath):")
            printSimpleDiff(old: oldHooksContent, new: newHooksContent)
            print("")
        }

        if configChanged {
            print("  \(configPath):")
            printSimpleDiff(old: existingConfigContent, new: newConfigContent)
            print("")
        }

        if !skipConfirm {
            print("Apply these changes? [Y/n] ", terminator: "")
            if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !response.isEmpty && response != "y" && response != "yes" {
                print("Aborted.")
                return
            }
        }

        if removedCount > 0 {
            try newJSONData.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)
        }
        if configChanged {
            try newConfigContent.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        print("Removed cmux Codex hooks.")
    }

    private func printSimpleDiff(old: String, new: String, contextLines: Int = 2) {
        let red = "\u{001B}[31m"
        let green = "\u{001B}[32m"
        let dim = "\u{001B}[2m"
        let reset = "\u{001B}[0m"

        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let lcs = longestCommonSubsequence(oldLines, newLines)

        struct DiffLine {
            enum Kind { case context, remove, add }
            let kind: Kind
            let lineNo: Int
            let text: String
        }

        var oldIndex = 0
        var newIndex = 0
        var lcsIndex = 0
        var allDiffs: [DiffLine] = []

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if lcsIndex < lcs.count,
               oldIndex < oldLines.count,
               newIndex < newLines.count,
               oldLines[oldIndex] == lcs[lcsIndex],
               newLines[newIndex] == lcs[lcsIndex] {
                allDiffs.append(DiffLine(kind: .context, lineNo: newIndex + 1, text: newLines[newIndex]))
                oldIndex += 1
                newIndex += 1
                lcsIndex += 1
            } else if oldIndex < oldLines.count && (lcsIndex >= lcs.count || oldLines[oldIndex] != lcs[lcsIndex]) {
                allDiffs.append(DiffLine(kind: .remove, lineNo: oldIndex + 1, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count {
                allDiffs.append(DiffLine(kind: .add, lineNo: newIndex + 1, text: newLines[newIndex]))
                newIndex += 1
            }
        }

        var changedIndices = Set<Int>()
        for (index, diff) in allDiffs.enumerated() where diff.kind != .context {
            for expanded in max(0, index - contextLines)...min(allDiffs.count - 1, index + contextLines) {
                changedIndices.insert(expanded)
            }
        }

        var lastPrinted = -1
        for index in changedIndices.sorted() {
            if lastPrinted >= 0 && index > lastPrinted + 1 {
                print("    \(dim)...\(reset)")
            }
            let diff = allDiffs[index]
            let lineLabel = String(format: "%3d", diff.lineNo)
            switch diff.kind {
            case .context:
                print("    \(dim)\(lineLabel)  \(diff.text)\(reset)")
            case .remove:
                print("    \(red)\(lineLabel) -\(diff.text)\(reset)")
            case .add:
                print("    \(green)\(lineLabel) +\(diff.text)\(reset)")
            }
            lastPrinted = index
        }
    }

    private func longestCommonSubsequence(_ lhs: [String], _ rhs: [String]) -> [String] {
        let lhsCount = lhs.count
        let rhsCount = rhs.count
        var dp = Array(repeating: Array(repeating: 0, count: rhsCount + 1), count: lhsCount + 1)

        if lhsCount > 0 && rhsCount > 0 {
            for lhsIndex in 1...lhsCount {
                for rhsIndex in 1...rhsCount {
                    if lhs[lhsIndex - 1] == rhs[rhsIndex - 1] {
                        dp[lhsIndex][rhsIndex] = dp[lhsIndex - 1][rhsIndex - 1] + 1
                    } else {
                        dp[lhsIndex][rhsIndex] = max(dp[lhsIndex - 1][rhsIndex], dp[lhsIndex][rhsIndex - 1])
                    }
                }
            }
        }

        var result: [String] = []
        var lhsIndex = lhsCount
        var rhsIndex = rhsCount
        while lhsIndex > 0 && rhsIndex > 0 {
            if lhs[lhsIndex - 1] == rhs[rhsIndex - 1] {
                result.append(lhs[lhsIndex - 1])
                lhsIndex -= 1
                rhsIndex -= 1
            } else if dp[lhsIndex - 1][rhsIndex] > dp[lhsIndex][rhsIndex - 1] {
                lhsIndex -= 1
            } else {
                rhsIndex -= 1
            }
        }

        return result.reversed()
    }

    private func buildConfigWithCodexHooks(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")

        if let existingKeyIndex = lines.firstIndex(where: { isTomlKey($0, key: "codex_hooks") }) {
            lines[existingKeyIndex] = "codex_hooks = true"
            return lines.joined(separator: "\n")
        }

        if let featuresIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            lines.insert("codex_hooks = true", at: featuresIndex + 1)
            return lines.joined(separator: "\n")
        }

        var result = content
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        result += "\n[features]\ncodex_hooks = true\n"
        return result
    }

    private func buildConfigWithoutCodexHooks(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        lines.removeAll { isTomlKey($0, key: "codex_hooks") }

        if let featuresIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            let nextNonEmptyIndex = lines[(featuresIndex + 1)...].firstIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            })
            let sectionEmpty = nextNonEmptyIndex == nil || lines[nextNonEmptyIndex!].trimmingCharacters(in: .whitespaces).hasPrefix("[")
            if sectionEmpty {
                lines.remove(at: featuresIndex)
            }
        }

        return lines.joined(separator: "\n")
    }

    private func isTomlKey(_ line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), trimmed.hasPrefix(key) else { return false }
        let remainder = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return remainder.hasPrefix("=")
    }
}
