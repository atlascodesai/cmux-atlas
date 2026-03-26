import Foundation

extension AppDelegate {
    func startAISessionCacheRefreshTimerIfNeeded() {
        guard aiSessionCacheRefreshTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = Self.aiSessionCacheRefreshInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isTerminatingApp else { return }
            self.scheduleAISessionCacheRefreshAcrossAllWorkspaces()
        }
        aiSessionCacheRefreshTimer = timer
        timer.resume()
    }

    func scheduleAISessionCacheRefreshAcrossAllWorkspaces() {
        for tabManager in allTabManagers() {
            for workspace in tabManager.tabs {
                workspace.scheduleAISessionRefreshForTerminalPanels()
            }
        }
    }

    func refreshAISessionCachesNowAcrossAllWorkspaces() {
        for tabManager in allTabManagers() {
            for workspace in tabManager.tabs {
                workspace.refreshAISessionCacheNowForTerminalPanels()
            }
        }
    }
}
