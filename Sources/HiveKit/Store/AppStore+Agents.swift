import AppKit
import HiveCore

/// Estado de los agentes: lo que escribís, sus eventos, el silencio y los avisos.
extension AppStore {
    // MARK: - Estado de los agentes

    func userInput(_ id: UUID, _ data: ArraySlice<UInt8>) {
        guard let rt = runtimes[id] else { return }
        if rt.unseen { markSeen(rt) }
        guard rt.kind.isAgent else { return }
        if TerminalInput.isLoneEscape(data) {
            // Esc rechaza el pedido de permiso o interrumpe al agente: ya no trabaja ni espera que
            // le des permiso, te toca a vos. No hace falta avisarte: lo acabás de hacer vos.
            if rt.status == .attention || rt.status == .working {
                rt.workingSince = nil
                setStatus(rt, .waiting, quiet: true)
            }
            return
        }
        // Enter en un agente: mandaste un prompt o aprobaste algo, así que empieza a trabajar. No cuentan
        // el salto de línea (Shift+Enter, ⌥Enter) ni lo que llega dentro de un pegado.
        guard TerminalInput.isSubmit(data), rt.status != .working else { return }
        // Le escribiste: cuenta como usada hoy para el orden de los proyectos, también en un agente
        // que no avisa con hooks (Gemini), donde ningún evento lo anota.
        let now = environment.now()
        projects.updateSession(id) { $0.lastActivityAt = now }
        scheduleSave()
        setStatus(rt, .working)
    }

    /// Aplica los eventos de los agentes (los decide `AgentEventInterpreter`).
    func handle(_ events: [HiveEvent]) {
        for event in events {
            guard let rt = runtimes[event.sessionId], rt.isRunning, let ctx = sessionContext(event.sessionId) else { continue }
            rt.hooksSeen = true
            // Un thread de Codex distinto del de la sesión puede ser de un subagente: esos avisos se ignoran.
            let outcome = AgentEventInterpreter.interpret(event, status: rt.status, agentSessionId: ctx.session.agentSessionId,
                                                          isSubagentThread: environment.agents.isCodexSubagentThread,
                                                          pendingPermission: rt.pendingPermission)
            if !outcome.history.isEmpty {
                let place = ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)"
                history.ensureMarkdown(session: ctx.session, place: place)
                for entry in outcome.history {
                    history.append(HistoryEntry(date: environment.now(), role: entry.role, text: entry.text),
                                   sessionId: ctx.session.id, agentName: ctx.session.kind.label)
                }
                historyVersions[ctx.session.id, default: 0] += 1
                if let prompt = outcome.history.first(where: { $0.role == .user })?.text { autoName(ctx.session, prompt: prompt) }
            }
            keepTranscript(event, outcome: outcome, session: ctx.session)
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
            if let request = outcome.permissionRequest, rt.status == .attention { rt.pendingPermission = request }
        }
    }

    /// Guarda una copia del transcript completo del agente en el historial de Hive, para que sobreviva
    /// aunque el agente borre sus archivos. Claude manda su `transcript_path`; Codex no, así que al
    /// terminar cada turno se busca su rollout. Leer y copiar el transcript corre fuera del hilo principal.
    func keepTranscript(_ event: HiveEvent, outcome: AgentEventOutcome, session: Session) {
        let history = self.history
        let sessionId = session.id
        let agent = session.kind
        if let transcript = outcome.transcript {
            history.recordTranscript(sessionId: sessionId, agent: agent, conversationId: transcript.conversationId,
                                     path: transcript.path, now: environment.now())
            let path = transcript.path
            Task.detached(priority: .utility) { history.archiveTranscript(sessionId: sessionId, agent: agent, path: path) }
        } else if event.source == "codex", event.payload["type"]?.string == "agent-turn-complete", outcome.status != nil,
                  let thread = outcome.agentSessionId ?? session.agentSessionId, !thread.isEmpty {
            let agents = environment.agents
            let now = environment.now()
            Task.detached(priority: .utility) {
                guard let rollout = agents.codexRolloutURL(thread) else { return }
                history.recordTranscript(sessionId: sessionId, agent: agent, conversationId: thread, path: rollout.path, now: now)
                history.archiveTranscript(sessionId: sessionId, agent: agent, path: rollout.path)
            }
        }
    }

    /// La primera vez que le pedís algo a un agente, la sesión toma ese nombre (si no la renombraste vos).
    func autoName(_ session: Session, prompt: String) {
        guard SessionTitle.canRename(session), let title = SessionTitle.from(prompt: prompt) else { return }
        projects.updateSession(session.id) { $0.name = title }
        scheduleSave()
    }

    /// Cambia el estado de una sesión. Si pasa a esperarte y no la estás mirando, la marca como
    /// pendiente y avisa con `body`. `quiet`: el cambio lo hiciste vos, no hay nada que avisar.
    func setStatus(_ rt: SessionRuntime, _ status: SessionStatus, notify body: String? = nil, quiet: Bool = false) {
        // El aviso de permiso se ve en la tarjeta mientras dure; un pedido nuevo lo reemplaza.
        if status == .attention, let body { rt.attentionNotice = body }
        guard rt.status != status else { return }
        rt.status = status
        if status != .attention {
            rt.attentionNotice = nil
            rt.pendingPermission = nil
        }
        if status == .working {
            rt.workingSince = environment.now()
        } else if status.needsYou && !quiet {
            if !isFocused(rt.sessionId) {
                rt.unseen = true
                if let body { postNotification(rt.sessionId, body: body, kind: status == .attention ? .permission : .turn) }
            }
            updateBadge()
        }
    }

    /// Cada segundo, la regla del silencio para los agentes que figuran trabajando.
    func tick() {
        let now = environment.now()
        for rt in runtimes.values where rt.kind.isAgent && rt.status == .working {
            let verdict = SilenceRule.evaluate(now: now, workingSince: rt.workingSince, lastOutput: rt.lastOutput, hooksSeen: rt.hooksSeen)
            if verdict.stopWorking { setStatus(rt, .waiting, notify: verdict.notify ? "Espera tu respuesta." : nil) }
        }
    }

    /// Aviso del sistema: con .permission solo se abre; con .turn se puede responder desde el aviso.
    func postNotification(_ id: UUID, body: String, kind: NotificationKind) {
        guard let ctx = sessionContext(id) else { return }
        environment.notifier.post(sessionId: id,
                                  title: ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)",
                                  subtitle: "\(ctx.session.name) · \(kind == .permission ? "Necesita permiso" : "Tu turno")",
                                  body: body, kind: kind)
    }

    func updateBadge() {
        let count = runtimes.values.filter(\.unseen).count
        environment.setDockBadge(count > 0 ? "\(count)" : nil)
    }
}
