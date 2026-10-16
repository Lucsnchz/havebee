import Foundation

/// No se infiere trabajo pendiente de «hay un historial»: hace falta haber visto al agente trabajar.
public struct PendingAgentWork: Codable, Hashable, Sendable {
    public var launchId: UUID
    /// Segundos con fracciones: las fechas ISO del estado se redondean y podrían incluir un turno anterior.
    public var since: TimeInterval
    public var backgroundAgents: Int

    public init(launchId: UUID, since: Date, backgroundAgents: Int = 0) {
        self.launchId = launchId
        self.since = since.timeIntervalSince1970
        self.backgroundAgents = backgroundAgents
    }
}

public enum InterruptedWork {
    public static let marker = "Hive retoma la tarea que quedó interrumpida"
    public static let prompt = """
    [Hive: reanudación de trabajo interrumpido]
    Esta conversación tenía trabajo pendiente cuando se cortó la sesión. Revisá el historial de esta misma conversación (también HIVE_HISTORY_FILE, si está disponible) y el estado actual del proyecto. Continuá únicamente la tarea ya autorizada que quedó pendiente, conservando sus objetivos y restricciones.
    Si había un workflow o subagentes, comprobá sus resultados y si siguen activos antes de retomarlos; no dupliques procesos ni repitas acciones ya realizadas. Si la tarea ya terminó, no la vuelvas a ejecutar. Este mensaje automático no responde preguntas pendientes ni concede permisos: si necesitabas una respuesta o aprobación del usuario, seguí esperando y explicá qué falta.
    """

    public static func isPrompt(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
    }

    /// Reconciliar los hooks que quedaron en disco al cerrar. Solo pertenecen al proceso guardado;
    /// un evento viejo, un subagente o la generación de títulos no puede reactivar una tarea.
    public static func reconcile(_ session: Session, events: [HiveEvent],
                                 isSubagentThread: (String) -> Bool = { _ in false }) -> PendingAgentWork? {
        guard var pending = session.pendingWork else { return nil }
        var status = SessionStatus.working
        var permission: PermissionRequestKey?
        for event in events where event.sessionId == session.id && event.source == session.kind.rawValue
            && event.launchId == pending.launchId {
            let outcome = AgentEventInterpreter.interpret(event, status: status, agentSessionId: session.agentSessionId,
                                                         isSubagentThread: isSubagentThread, pendingPermission: permission,
                                                         inBackground: pending.backgroundAgents > 0)
            if let count = outcome.backgroundAgents { pending.backgroundAgents = count }
            if let next = outcome.status { status = next }
            if let request = outcome.permissionRequest { permission = request }
        }
        return status == .working ? pending : nil
    }

    /// Última evidencia del transcript nativo. Evita repetir un turno terminado cuyo hook no llegó.
    /// Se lee solo el final, fuera del actor principal; los registros desconocidos no inventan estados.
    public static func allowsContinuation(transcript: URL, agent: SessionKind, pending: PendingAgentWork) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: transcript) else { return false }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd() else { return false }
        let offset = end > 1_048_576 ? end - 1_048_576 : 0
        do { try file.seek(toOffset: offset) } catch { return false }
        guard let data = try? file.readToEnd() else { return false }
        var lines = data.split(separator: 10)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        // En Codex el checkpoint puede venir de Enter en la terminal. Hace falta que el rollout
        // confirme que inició una tarea; Enter en un menú, /status o una entrada vacía no alcanzan.
        var allowed = agent != .codex
        var titleTurn = false
        for line in lines {
            guard let json = JSONValue.parse(Data(line)), let stamp = json["timestamp"]?.string.flatMap(AgentTimestamp.parse),
                  stamp.timeIntervalSince1970 >= pending.since else { continue }
            if agent == .codex {
                let payload = json["payload"]
                let type = payload?["type"]?.string
                if json["type"]?.string == "event_msg" {
                    if type == "task_started" { allowed = true; titleTurn = false }
                    if ["task_complete", "turn_aborted"].contains(type ?? ""), !titleTurn { allowed = false }
                } else if json["type"]?.string == "response_item", type == "message" {
                    let text = (payload?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                    if payload?["role"]?.string == "user" {
                        titleTurn = CodexTitleGeneration.isRequest(text)
                        if !titleTurn, !TranscriptReader.isCodexInjected(text) { allowed = true }
                        if text.hasPrefix("<turn_aborted>") { allowed = false }
                    } else if payload?["role"]?.string == "assistant", payload?["phase"]?.string == "final", !titleTurn {
                        allowed = false
                    }
                } else if json["type"]?.string == "response_item", ["function_call", "custom_tool_call"].contains(type ?? "") {
                    let name = payload?["name"]?.string ?? ""
                    allowed = !["request_user_input", "request_user_input_async"].contains { name == $0 || name.hasSuffix("." + $0) }
                }
            } else if agent == .claude, json["isSidechain"]?.asBool != true {
                let message = json["message"]
                if json["type"]?.string == "assistant" {
                    let tools = (message?["content"]?.array ?? []).filter { $0["type"]?.string == "tool_use" }
                    if tools.contains(where: { ["AskUserQuestion", "ExitPlanMode"].contains($0["name"]?.string ?? "") }) {
                        allowed = false
                    } else if !tools.isEmpty {
                        allowed = true
                    } else if message?["stop_reason"]?.string == "end_turn" {
                        allowed = false
                    }
                } else if json["type"]?.string == "user" {
                    let content = message?["content"]
                    let text = content?.string ?? (content?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                    if text.hasPrefix("[Request interrupted by user") { allowed = false }
                    else if !text.isEmpty { allowed = true }
                }
            }
        }
        return allowed
    }
}
