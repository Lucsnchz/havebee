import HiveCore
import Foundation

extension AppStore {
    /// Se escribe al cambiar de estado, no recién al salir: también cubre una caída de la app.
    /// El guardado inmediato evita perder un Stop/permiso por el debounce de la persistencia normal.
    func recordPendingWork(_ rt: SessionRuntime, status: SessionStatus) {
        guard !isShuttingDown, !rt.isStopping, rt.kind.isAgent, rt.kind != .gemini,
              let ctx = sessionContext(rt.sessionId) else { return }
        let previous = ctx.session.pendingWork
        let pending: PendingAgentWork?
        if status == .working {
            guard !rt.manuallyInterrupted else { return }
            if let previous, previous.launchId == rt.launchId, previous.backgroundAgents == rt.backgroundAgents { return }
            pending = PendingAgentWork(launchId: rt.launchId, since: environment.now(), backgroundAgents: rt.backgroundAgents)
        } else if status.needsYou {
            pending = nil
        } else {
            return
        }
        guard previous != pending else { return }
        projects.updateSession(rt.sessionId) { $0.pendingWork = pending }
        saveNow()
    }

    func clearPendingWork(_ id: UUID) {
        guard sessionContext(id)?.session.pendingWork != nil else { return }
        projects.updateSession(id) { $0.pendingWork = nil }
        saveNow()
    }

    /// Un Stop pudo llegar al disco cuando Hive ya no alcanzaba a procesarlo. Se aplica antes de
    /// purgar eventos y de abrir cualquier conversación, sin avisos ni nuevos procesos.
    func reconcileInterruptedWork() {
        let pending = projects.flatMap(\.allSessions).filter { $0.pendingWork != nil }
        guard !pending.isEmpty else { return }
        let events = EventWatcher.pendingEvents(in: environment.paths.eventsDir)
        var changed = false
        for session in pending {
            let work = InterruptedWork.reconcile(session, events: events,
                                                isSubagentThread: environment.agents.isCodexSubagentThread)
            if work != session.pendingWork {
                projects.updateSession(session.id) { $0.pendingWork = work }
                changed = true
            }
        }
        if changed { saveNow() }
    }
}
