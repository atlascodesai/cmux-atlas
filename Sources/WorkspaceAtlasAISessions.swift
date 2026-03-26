import Foundation
import Combine

final class WorkspaceAtlasAISessionStore: ObservableObject {
    @Published private(set) var activeSessions: [UUID: ActiveAISessionSnapshot] = [:]
    @Published private(set) var cachedSessions: [UUID: AISessionSnapshot] = [:]

    private var refreshGenerationByPanel: [UUID: UUID] = [:]
    private let refreshQueue = DispatchQueue(
        label: "com.cmux.ai-session-refresh",
        qos: .utility
    )

    func removeAllActiveSessions() {
        activeSessions.removeAll()
    }

    func prune(validSurfaceIds: Set<UUID>) {
        activeSessions = activeSessions.filter { validSurfaceIds.contains($0.key) }
        cachedSessions = cachedSessions.filter { validSurfaceIds.contains($0.key) }
        refreshGenerationByPanel = refreshGenerationByPanel.filter { validSurfaceIds.contains($0.key) }
    }

    func clearCachedSession(panelId: UUID) {
        cachedSessions.removeValue(forKey: panelId)
    }

    func setCachedSession(_ snapshot: AISessionSnapshot?, panelId: UUID) {
        if let snapshot {
            cachedSessions[panelId] = snapshot
        } else {
            cachedSessions.removeValue(forKey: panelId)
        }
    }

    func beginRefreshGeneration(panelId: UUID) -> UUID {
        let generation = UUID()
        refreshGenerationByPanel[panelId] = generation
        return generation
    }

    func isRefreshGenerationCurrent(_ generation: UUID, panelId: UUID) -> Bool {
        refreshGenerationByPanel[panelId] == generation
    }

    func finishRefreshGeneration(panelId: UUID) {
        refreshGenerationByPanel.removeValue(forKey: panelId)
    }

    func scheduleRefresh(
        after delay: TimeInterval,
        perform work: @escaping @Sendable () -> Void
    ) {
        refreshQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func registerActiveSession(panelId: UUID, snapshot: ActiveAISessionSnapshot) {
        activeSessions[panelId] = snapshot
    }

    func clearActiveSession(panelId: UUID, agentType: AIAgentType? = nil) {
        guard let current = activeSessions[panelId] else { return }
        if let agentType, current.agentType != agentType {
            return
        }
        activeSessions.removeValue(forKey: panelId)
    }

    func activeSession(panelId: UUID, agentType: AIAgentType? = nil) -> ActiveAISessionSnapshot? {
        guard let snapshot = activeSessions[panelId] else { return nil }
        if let agentType, snapshot.agentType != agentType {
            return nil
        }
        return snapshot
    }

    func hasActiveSession(for agentType: AIAgentType) -> Bool {
        activeSessions.values.contains(where: { $0.agentType == agentType })
    }
}

extension Workspace {
    var activeAISessions: [UUID: ActiveAISessionSnapshot] {
        atlasAISessionStore.activeSessions
    }

    var cachedAISessions: [UUID: AISessionSnapshot] {
        atlasAISessionStore.cachedSessions
    }

    func scheduleAISessionRefreshForTerminalPanels() {
        let terminalPanelIds = panels.compactMap { panelId, panel in
            panel.panelType == .terminal ? panelId : nil
        }
        for panelId in terminalPanelIds {
            scheduleAISessionRefresh(panelId: panelId)
        }
    }

    func refreshAISessionCacheNowForTerminalPanels() {
        let terminalPanelIds = panels.compactMap { panelId, panel in
            panel.panelType == .terminal ? panelId : nil
        }
        for panelId in terminalPanelIds {
            refreshAISessionCacheNow(panelId: panelId)
        }
    }

    private func scheduleAISessionRefresh(panelId: UUID, delay: TimeInterval = 0.4) {
        guard panels[panelId]?.panelType == .terminal else {
            atlasAISessionStore.clearCachedSession(panelId: panelId)
            atlasAISessionStore.finishRefreshGeneration(panelId: panelId)
            return
        }

        let ttyName = surfaceTTYNames[panelId]
        let workingDirectory = panelDirectories[panelId] ?? currentDirectory
        let workspaceId = id
        let generation = atlasAISessionStore.beginRefreshGeneration(panelId: panelId)

        atlasAISessionStore.scheduleRefresh(after: delay) { [weak self] in
            let snapshot = AISessionDetector.detect(
                ttyName: ttyName,
                workingDirectory: workingDirectory,
                workspaceId: workspaceId,
                panelId: panelId
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.atlasAISessionStore.isRefreshGenerationCurrent(generation, panelId: panelId) else { return }
                self.atlasAISessionStore.finishRefreshGeneration(panelId: panelId)

                guard self.panels[panelId]?.panelType == .terminal else {
                    self.atlasAISessionStore.clearCachedSession(panelId: panelId)
                    return
                }

                self.atlasAISessionStore.setCachedSession(snapshot, panelId: panelId)
            }
        }
    }

    private func refreshAISessionCacheNow(panelId: UUID) {
        guard panels[panelId]?.panelType == .terminal else {
            atlasAISessionStore.clearCachedSession(panelId: panelId)
            atlasAISessionStore.finishRefreshGeneration(panelId: panelId)
            return
        }

        atlasAISessionStore.finishRefreshGeneration(panelId: panelId)
        let ttyName = surfaceTTYNames[panelId]
        let workingDirectory = panelDirectories[panelId] ?? currentDirectory
        let snapshot = AISessionDetector.detect(
            ttyName: ttyName,
            workingDirectory: workingDirectory,
            workspaceId: id,
            panelId: panelId
        )
        atlasAISessionStore.setCachedSession(snapshot, panelId: panelId)
    }

    func registerActiveAISession(panelId: UUID, snapshot: ActiveAISessionSnapshot) {
        guard panels[panelId]?.panelType == .terminal else { return }
        atlasAISessionStore.registerActiveSession(panelId: panelId, snapshot: snapshot)
    }

    func clearActiveAISession(panelId: UUID, agentType: AIAgentType? = nil) {
        atlasAISessionStore.clearActiveSession(panelId: panelId, agentType: agentType)
    }

    func activeAISession(panelId: UUID, agentType: AIAgentType? = nil) -> ActiveAISessionSnapshot? {
        atlasAISessionStore.activeSession(panelId: panelId, agentType: agentType)
    }

    func hasActiveAISession(for agentType: AIAgentType) -> Bool {
        atlasAISessionStore.hasActiveSession(for: agentType)
    }
}
