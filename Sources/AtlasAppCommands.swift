import AppKit
import SwiftUI

@MainActor
func atlasCreateWorkspace(activeTabManager: TabManager) {
    if let appDelegate = AppDelegate.shared {
        if appDelegate.addWorkspaceInPreferredMainWindow(debugSource: "menu.newWorkspace") == nil {
#if DEBUG
            FocusLogStore.shared.append(
                "cmdn.route phase=fallback_new_window src=menu.newWorkspace reason=workspace_creation_returned_nil"
            )
#endif
            appDelegate.openNewMainWindow(nil)
        }
    } else {
        activeTabManager.addTab()
    }
}

@MainActor
func atlasOpenFolder(activeTabManager: TabManager) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.title = String(localized: "menu.file.openFolder.panelTitle", defaultValue: "Open Folder")
    panel.prompt = String(localized: "menu.file.openFolder.panelPrompt", defaultValue: "Open")

    guard panel.runModal() == .OK, let url = panel.url else { return }

    if let appDelegate = AppDelegate.shared {
        if appDelegate.addWorkspaceInPreferredMainWindow(
            workingDirectory: url.path,
            debugSource: "menu.openFolder"
        ) == nil {
            appDelegate.openNewMainWindow(nil)
        }
    } else {
        activeTabManager.addWorkspace(workingDirectory: url.path)
    }
}

struct AtlasNewItemCommands: Commands {
    let activeTabManager: TabManager
    let newWindowMenuShortcut: StoredShortcut

    var body: some Commands {
        CommandGroup(after: .newItem) {
            storedShortcutButton(
                title: String(localized: "menu.file.newOrganization", defaultValue: "New Organization"),
                shortcut: newWindowMenuShortcut,
                action: createOrganizationWindow
            )

            Divider()

            Button(String(localized: "menu.file.newClaudeCodeTab", defaultValue: "New Claude Code Tab")) {
                activeTabManager.selectedWorkspace?.launchQuickAIAgent(.claudeCode)
            }
            .keyboardShortcut("a", modifiers: [.command, .option])

            Button(String(localized: "menu.file.newCodexTab", defaultValue: "New Codex Tab")) {
                activeTabManager.selectedWorkspace?.launchQuickAIAgent(.codex)
            }
            .keyboardShortcut("o", modifiers: [.command, .option])

            Divider()

            organizationsMenu
        }
    }

    @ViewBuilder
    private func storedShortcutButton(
        title: String,
        shortcut: StoredShortcut,
        action: @escaping () -> Void
    ) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(title, action: action)
                .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(title, action: action)
        }
    }

    private func createOrganizationWindow() {
        AppDelegate.shared?.openNewMainWindow(nil)
    }

    @ViewBuilder
    private var organizationsMenu: some View {
        let organizations = WorkspaceOrganizationStore.loadAll()
        let currentOrganizationName = activeTabManager.organizationName

        Menu(String(localized: "menu.file.organizations", defaultValue: "Organizations")) {
            if !organizations.isEmpty {
                ForEach(Array(organizations.prefix(10).enumerated()), id: \.element.id) { _, organization in
                    Button {
                        AppDelegate.shared?.openOrganizationInNewWindow(organization)
                    } label: {
                        HStack {
                            Text(organization.name)
                            if currentOrganizationName == organization.name {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()
            }

            Button(String(localized: "menu.file.organizations.rename", defaultValue: "Rename Organization…")) {
                renameOrganization()
            }

            Divider()

            Button(String(localized: "menu.file.organizations.exportCurrent", defaultValue: "Export Organization…")) {
                let name = activeTabManager.organizationName
                    ?? String(localized: "organization.defaultName", defaultValue: "Organization")
                let snapshot = activeTabManager.sessionSnapshot(includeScrollback: true)
                WorkspaceOrganizationStore.exportOrganization(snapshot, name: name)
            }

            Button(String(localized: "menu.file.organizations.import", defaultValue: "Import Organization…")) {
                if let organization = WorkspaceOrganizationStore.importWorkspace() {
                    AppDelegate.shared?.openOrganizationInNewWindow(organization)
                }
            }

            if !organizations.isEmpty {
                Divider()

                Menu(String(localized: "menu.file.organizations.remove", defaultValue: "Remove…")) {
                    ForEach(organizations, id: \.id) { organization in
                        Button(String.localizedStringWithFormat(
                            String(localized: "menu.file.organizations.remove.named", defaultValue: "Remove \"%@\""),
                            organization.name
                        )) {
                            WorkspaceOrganizationStore.remove(organization.id)
                        }
                    }
                }
            }
        }
    }

    private func renameOrganization() {
        let alert = NSAlert()
        alert.messageText = String(localized: "organization.rename.title", defaultValue: "Rename Organization")
        alert.informativeText = String(localized: "organization.rename.message", defaultValue: "Enter a new name for this organization.")
        alert.addButton(withTitle: String(localized: "organization.name.save", defaultValue: "Save"))
        alert.addButton(withTitle: String(localized: "organization.name.cancel", defaultValue: "Cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = activeTabManager.organizationName ?? ""
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        activeTabManager.organizationName = newName
    }
}
