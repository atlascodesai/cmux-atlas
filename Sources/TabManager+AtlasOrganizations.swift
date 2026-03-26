import Foundation

extension TabManager {
    func switchToOrganization(_ org: WorkspaceOrganization) {
        autoSaveCurrentOrganization()

        restoreSessionSnapshot(org.tabManagerSnapshot)
        organizationName = org.name
        WorkspaceOrganizationStore.touchLastUsed(org.id)
    }

    func saveCurrentAsOrganization(name: String) {
        let snapshot = sessionSnapshot(includeScrollback: false)
        let existing = WorkspaceOrganizationStore.loadAll()
        if existing.count >= WorkspaceOrganizationStore.maxOrganizations,
           existing.first(where: {
               $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
           }) == nil,
           let oldest = existing.last {
            WorkspaceOrganizationStore.remove(oldest.id)
        }
        _ = WorkspaceOrganizationStore.upsertAutomaticSnapshot(name: name, tabManagerSnapshot: snapshot)
        organizationName = name
    }

    func autoSaveCurrentOrganization() {
        guard let name = organizationName, !name.isEmpty else { return }
        let snapshot = sessionSnapshot(includeScrollback: false)
        _ = WorkspaceOrganizationStore.upsertAutomaticSnapshot(name: name, tabManagerSnapshot: snapshot)
    }
}
