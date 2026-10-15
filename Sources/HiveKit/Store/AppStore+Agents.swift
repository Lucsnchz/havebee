import AppKit
import HiveCore

/// Estado de los agentes: lo que escribís, sus eventos, el silencio y los avisos.
extension AppStore {
    // MARK: - Estado de los agentes

    func userInput(_ id: UUID, _ data: ArraySlice<UInt8>) {
        guard let rt = runtimes[id] else { return }
        if rt.unseen { markSeen(rt) }
        guard rt.kind.isAgent else { return }
        if AgentKeystrokes.isLoneEscape(data) {
            // Esc rechaza el pedido de permiso o interrumpe al agente: ya no trabaja ni espera que
            // le des permiso, te toca a vos. No hace falta avisarte: lo acabás de hacer vos.
            if rt.status == .attention || rt.status == .working {
                rt.workingSince = nil
                setStatus(rt, .waiting, quiet: true)
            }
            return
        }
        // Enter en un agente: mandaste un prompt o aprobaste algo, así que empieza a trabajar.
        guard AgentKeystrokes.isSubmit(data), rt.status != .working else { return }
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
                if let prompt = outcome.history.first(where: { $0.role == .user })?.text { autoName(ctx.session, prompt: prompt) }
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
        if status != .attention { rt.attentionNotice = nil }
        if status == .working {
            rt.workingSince = environment.now()
        } else if status.needsYou && !quiet {
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
            let verdict = SilenceRule.evaluate(now: now, workingSince: rt.workingSince, lastOutput: rt.lastOutput, hooksSeen: rt.hooksSeen)
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

/// Qué teclas cambian el estado de un agente. (En la integración se reemplaza por TerminalInput,
/// de la terminal.)
private enum AgentKeystrokes {
    static let escape: UInt8 = 0x1B
    static let carriageReturn: UInt8 = 0x0D
    /// ESC[200~: empieza un pegado (bracketed paste).
    static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]

    /// Esc solo (no el comienzo de una secuencia, como una flecha).
    static func isLoneEscape(_ data: ArraySlice<UInt8>) -> Bool {
        data.count == 1 && data.first == escape
    }

    /// Un Enter que manda lo escrito: un CR suelto. No cuentan un CR después de ESC (Option+Enter:
    /// salto de línea), las secuencias CSI-u con modificadores (ESC[13;2u, Shift+Enter, que no
    /// traen un CR) ni lo que llega dentro de un pegado.
    static func isSubmit(_ data: ArraySlice<UInt8>) -> Bool {
        if data.starts(with: pasteStart) { return false }
        var previous: UInt8?
        for byte in data {
            if byte == carriageReturn && previous != escape { return true }
            previous = byte
        }
        return false
    }
}
