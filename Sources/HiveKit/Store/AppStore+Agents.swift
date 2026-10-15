import AppKit
import HiveCore

/// Estado de los agentes: lo que escribís, sus eventos, el silencio y los avisos.
extension AppStore {
    // MARK: - Estado de los agentes

    func userInput(_ id: UUID, _ data: ArraySlice<UInt8>) {
        guard let rt = runtimes[id] else { return }
        if rt.unseen { markSeen(rt) }
        // Enter en un agente: mandaste un prompt o aprobaste algo, así que empieza a trabajar.
        guard rt.kind.isAgent, data.contains(13), rt.status != .working else { return }
        setStatus(rt, .working)
    }

    /// Aplica los eventos de los agentes (los decide `AgentEventInterpreter`).
    func handle(_ events: [HiveEvent]) {
        for event in events {
            guard let rt = runtimes[event.sessionId], rt.isRunning, let ctx = sessionContext(event.sessionId) else { continue }
            rt.hooksSeen = true
            let outcome = AgentEventInterpreter.interpret(event, status: rt.status, agentSessionId: ctx.session.agentSessionId)
            if !outcome.history.isEmpty {
                let place = ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)"
                history.ensureMarkdown(session: ctx.session, place: place)
                for entry in outcome.history {
                    history.append(HistoryEntry(date: environment.now(), role: entry.role, text: entry.text),
                                   sessionId: ctx.session.id, agentName: ctx.session.kind.label)
                }
                historyVersions[ctx.session.id, default: 0] += 1
            }
            if outcome.agentSessionId != nil || outcome.reply != nil || outcome.touchesActivity {
                let now = environment.now()
                projects.updateSession(event.sessionId) { session in
                    if let id = outcome.agentSessionId { session.agentSessionId = id }
                    if let reply = outcome.reply { session.lastMessage = reply }
                    if outcome.touchesActivity { session.lastActivityAt = now }
                }
                scheduleSave()
            }
            if let status = outcome.status { setStatus(rt, status, notify: outcome.notification) }
        }
    }

    func setStatus(_ rt: SessionRuntime, _ status: SessionStatus, notify body: String? = nil) {
        guard rt.status != status else { return }
        rt.status = status
        if status == .working {
            rt.workingSince = environment.now()
        } else if status.needsYou {
            if !isFocused(rt.sessionId) {
                rt.unseen = true
                if let body { postNotification(rt.sessionId, body: body, attention: status == .attention) }
            }
            updateBadge()
        }
    }

    /// Cada segundo, la regla del silencio para los agentes que figuran trabajando.
    func tick() {
        let now = environment.now()
        for rt in runtimes.values where rt.kind.isAgent && rt.status == .working {
            let verdict = SilenceRule.evaluate(now: now, workingSince: rt.workingSince, lastOutput: rt.activity.last, hooksSeen: rt.hooksSeen)
            if verdict.stopWorking { setStatus(rt, .waiting, notify: verdict.notify ? "Espera tu respuesta." : nil) }
        }
    }

    func postNotification(_ id: UUID, body: String, attention: Bool) {
        guard let ctx = sessionContext(id) else { return }
        environment.notifier.post(sessionId: id,
                                  title: ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)",
                                  subtitle: "\(ctx.session.name) · \(attention ? "Necesita permiso" : "Tu turno")",
                                  body: body)
    }

    func updateBadge() {
        let count = runtimes.values.filter(\.unseen).count
        environment.setDockBadge(count > 0 ? "\(count)" : nil)
    }
}
