import Foundation

/// Un aviso de un agente (hook de Claude o notify de Codex) que escribió `hive-event`.
public struct HiveEvent: Equatable, Sendable {
    public let sessionId: UUID
    public let source: String
    public let name: String
    public let payload: JSONValue

    public init(sessionId: UUID, source: String, name: String, payload: JSONValue = .object([:])) {
        self.sessionId = sessionId
        self.source = source
        self.name = name
        self.payload = payload
    }

    /// Formato del archivo `.evt`: una línea "<sesión>\t<origen>\t<evento>" y después el JSON.
    public static func parse(_ text: String) -> HiveEvent? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let header = first.split(separator: "\t").map(String.init)
        guard header.count >= 3, let id = UUID(uuidString: header[0]) else { return nil }
        let payload = parts.count > 1 ? (JSONValue.parse(String(parts[1])) ?? .object([:])) : .object([:])
        return HiveEvent(sessionId: id, source: header[1], name: header[2], payload: payload)
    }
}

/// Lo que hay que hacer con una sesión después de un evento.
public struct AgentEventOutcome: Equatable, Sendable {
    /// Nuevo estado (nil: no cambia).
    public var status: SessionStatus?
    /// Texto del aviso si la sesión pasa a esperarte y no la estás mirando.
    public var notification: String?
    /// Nuevo ID de conversación del agente (cambia con /clear o /new).
    public var agentSessionId: String?
    /// Mensajes para el historial, en orden.
    public var history: [(role: HistoryEntry.Role, text: String)]
    /// Resumen de la última respuesta, para la tarjeta de la sesión.
    public var reply: String?
    /// Si hubo actividad del usuario o del agente (para "hace cuánto se usó").
    public var touchesActivity: Bool

    public init(status: SessionStatus? = nil, notification: String? = nil, agentSessionId: String? = nil,
                history: [(role: HistoryEntry.Role, text: String)] = [], reply: String? = nil, touchesActivity: Bool = false) {
        self.status = status
        self.notification = notification
        self.agentSessionId = agentSessionId
        self.history = history
        self.reply = reply
        self.touchesActivity = touchesActivity
    }

    public static func == (a: AgentEventOutcome, b: AgentEventOutcome) -> Bool {
        a.status == b.status && a.notification == b.notification && a.agentSessionId == b.agentSessionId
            && a.history.map(\.role) == b.history.map(\.role) && a.history.map(\.text) == b.history.map(\.text)
            && a.reply == b.reply && a.touchesActivity == b.touchesActivity
    }
}

/// Traduce los eventos de los agentes a cambios de estado. Sin efectos: el store aplica el resultado.
public enum AgentEventInterpreter {
    public static let defaultNotification = "Terminó. Es tu turno."
    public static let permissionNotification = "Necesita tu permiso para seguir."

    public static func interpret(_ event: HiveEvent, status: SessionStatus, agentSessionId: String?) -> AgentEventOutcome {
        var outcome = AgentEventOutcome()
        let payload = event.payload
        switch (event.source, event.name) {
        case ("claude", "SessionStart"):
            // Cambia con /clear: guardamos el nuevo para reanudar la conversación correcta.
            if let id = payload["session_id"]?.string, id != agentSessionId { outcome.agentSessionId = id }
            if let source = payload["source"]?.string, source == "clear" || source == "compact" {
                outcome.history = [(.marker, "/\(source)")]
            }
        case ("claude", "UserPromptSubmit"):
            outcome.status = .working
            outcome.touchesActivity = true
            if let prompt = payload["prompt"]?.string { outcome.history = [(.user, prompt)] }
        case ("claude", "PreToolUse"), ("claude", "PostToolUse"):
            outcome.status = .working
        case ("claude", "Notification"):
            let type = payload["notification_type"]?.string ?? ""
            let message = payload["message"]?.string ?? ""
            if type == "permission_prompt" || type == "elicitation_dialog" || message.localizedCaseInsensitiveContains("permission") {
                outcome.status = .attention
                outcome.notification = message.isEmpty ? permissionNotification : message
            } else if status == .working {
                // "Claude está esperando tu respuesta" después de un rato sin actividad.
                outcome.status = .waiting
                outcome.notification = message.isEmpty ? nil : message
            }
        case ("claude", "Stop"):
            let full = payload["last_assistant_message"]?.string
            if let full { outcome.history = [(.assistant, full)] }
            outcome.reply = summary(full)
            outcome.touchesActivity = true
            outcome.status = .waiting
            outcome.notification = outcome.reply ?? defaultNotification
        case ("codex", _):
            if let thread = payload["thread-id"]?.string, !thread.isEmpty, thread != agentSessionId {
                // Un thread nuevo en la misma sesión es un /new o /clear de Codex.
                if agentSessionId != nil { outcome.history.append((.marker, "Nueva conversación")) }
                outcome.agentSessionId = thread
            }
            if payload["type"]?.string == "agent-turn-complete" {
                let inputs = payload["input-messages"]?.stringArray ?? []
                if !inputs.isEmpty { outcome.history.append((.user, inputs.joined(separator: "\n\n"))) }
                let full = payload["last-assistant-message"]?.string
                if let full { outcome.history.append((.assistant, full)) }
                outcome.reply = summary(full)
                outcome.touchesActivity = true
                outcome.status = .waiting
                outcome.notification = outcome.reply ?? defaultNotification
            }
        default:
            break
        }
        // Los textos vacíos no van al historial.
        outcome.history = outcome.history.compactMap { entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (entry.role, text)
        }
        return outcome
    }

    /// Una línea de hasta 200 caracteres para avisos y tarjetas.
    public static func summary(_ text: String?) -> String? {
        guard let text else { return nil }
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}

/// Regla de respaldo para cuando no llegan eventos: un agente "trabajando" que deja de producir
/// salida ya no está trabajando (terminó, lo interrumpiste o espera algo). Claude y Codex
/// animan su spinner mientras trabajan, así que el silencio es una señal confiable.
public enum SilenceRule {
    public static let silence: TimeInterval = 6
    public static let sustained: TimeInterval = 4

    public struct Verdict: Equatable, Sendable {
        public let stopWorking: Bool
        public let notify: Bool
    }

    public static func evaluate(now: Date, workingSince: Date?, lastOutput: Date, hooksSeen: Bool) -> Verdict {
        let since = workingSince ?? now
        guard now.timeIntervalSince(max(lastOutput, since)) > silence else { return Verdict(stopWorking: false, notify: false) }
        // Solo avisamos si de verdad estuvo trabajando un rato y el agente no tiene eventos propios.
        let wasBusy = lastOutput.timeIntervalSince(since) > sustained
        return Verdict(stopWorking: true, notify: wasBusy && !hooksSeen)
    }
}
