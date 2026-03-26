import SwiftUI

struct CMUXCoreNewItemCommands: Commands {
    let activeTabManager: TabManager
    let newWorkspaceMenuShortcut: StoredShortcut
    let openFolderMenuShortcut: StoredShortcut

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            storedShortcutButton(
                title: String(localized: "menu.file.newWorkspace", defaultValue: "New Workspace"),
                shortcut: newWorkspaceMenuShortcut
            ) {
                atlasCreateWorkspace(activeTabManager: activeTabManager)
            }

            storedShortcutButton(
                title: String(localized: "menu.file.openFolder", defaultValue: "Open Folder…"),
                shortcut: openFolderMenuShortcut
            ) {
                atlasOpenFolder(activeTabManager: activeTabManager)
            }
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
}
