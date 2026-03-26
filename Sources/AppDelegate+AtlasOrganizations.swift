import Foundation

extension AppDelegate {
    /// Opens a saved organization in a new window.
    func openOrganizationInNewWindow(_ org: WorkspaceOrganization) {
        let snapshot = SessionWindowSnapshot(
            tabManager: org.tabManagerSnapshot,
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs)
        )
        let windowId = createMainWindow(sessionWindowSnapshot: snapshot)
        if let tabManager = tabManagerFor(windowId: windowId) {
            tabManager.organizationName = org.name
            WorkspaceOrganizationStore.touchLastUsed(org.id)
        }
    }
}
