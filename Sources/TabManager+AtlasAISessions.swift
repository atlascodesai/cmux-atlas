import Foundation
import Darwin

extension TabManager {
    /// Periodically checks tracked agent processes.
    /// Stale status PIDs are cleared, and live AI sessions can prefill a resume
    /// command when their backing process exits without a dedicated hook.
    func startAgentPIDSweepTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sweepStaleAgentPIDs()
            }
        }
        timer.resume()
        agentPIDSweepTimer = timer
    }

    func sweepStaleAgentPIDs() {
        func isProcessAlive(_ pid: pid_t) -> Bool {
            guard pid > 0 else { return false }
            // kill(pid, 0) probes process liveness without sending a signal.
            // ESRCH = process doesn't exist (stale). EPERM = process exists
            // but we lack permission (not stale, keep tracking).
            errno = 0
            if kill(pid, 0) == -1, POSIXErrorCode(rawValue: errno) == .ESRCH {
                return false
            }
            return true
        }

        for tab in tabs {
            var keysToRemove: [String] = []
            for (key, pid) in tab.agentPIDs {
                if !isProcessAlive(pid) {
                    keysToRemove.append(key)
                }
            }

            let deadActiveSessions = tab.activeAISessions.compactMap { panelId, snapshot -> (UUID, ActiveAISessionSnapshot)? in
                guard let pid = snapshot.pid else { return nil }
                return isProcessAlive(pid) ? nil : (panelId, snapshot)
            }

            for (panelId, snapshot) in deadActiveSessions {
                if let terminalPanel = tab.terminalPanel(for: panelId) {
                    terminalPanel.prefillResumeAction(snapshot.restoredTerminalAction)
                }
                tab.clearActiveAISession(panelId: panelId, agentType: snapshot.agentType)
            }

            if !keysToRemove.isEmpty {
                for key in keysToRemove {
                    tab.statusEntries.removeValue(forKey: key)
                    tab.agentPIDs.removeValue(forKey: key)
                }
                AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)
            }
        }
    }
}

#if DEBUG
extension TabManager {
    @MainActor
    func sweepAgentProcessesForTesting() {
        sweepStaleAgentPIDs()
    }
}
#endif
