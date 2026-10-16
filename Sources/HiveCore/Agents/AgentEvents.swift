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

/// La herramienta que pidió permiso (PermissionRequest de Claude). Mientras el diálogo está abierto,
/// otras herramientas que corren en paralelo pueden terminar: sus hooks no sacan a la sesión de
/// «Necesita permiso».
public struct PermissionRequestKey: Equatable, Sendable {
    public let toolName: String
    public let input: JSONValue?

    public init(toolName: String, input: JSONValue?) {
        self.toolName = toolName
        self.input = input
    }

    /// La de un hook de Claude (`tool_name` y `tool_input`).
    public init(payload: JSONValue) {
        self.init(toolName: payload["tool_name"]?.string ?? "", input: payload["tool_input"])
    }

    /// Si un hook de herramienta es de la misma que pidió permiso. Si falta la entrada en alguno de
    /// los dos, alcanza con el nombre.
    public func matches(_ payload: JSONValue) -> Bool {
        guard (payload["tool_name"]?.string ?? "") == toolName else { return false }
        guard let input, let other = payload["tool_input"] else { return true }
        return input == other
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
    /// Transcript completo de la conversación (`transcript_path` de Claude), para guardarlo en Hive.
    public var transcript: (conversationId: String, path: String)?
    /// La herramienta que acaba de pedir permiso (el store la recuerda mientras siga en «Necesita permiso»).
    public var permissionRequest: PermissionRequestKey?
    /// Subagentes o workflows que siguen trabajando con el agente principal quieto (nil: no cambia).
    /// El Stop dice cuántos quedan; un turno nuevo del agente principal lo vuelve a 0.
    public var backgroundAgents: Int?

    public init(status: SessionStatus? = nil, notification: String? = nil, agentSessionId: String? = nil,
                history: [(role: HistoryEntry.Role, text: String)] = [], reply: String? = nil, touchesActivity: Bool = false,
                transcript: (conversationId: String, path: String)? = nil) {
        self.status = status
        self.notification = notification
        self.agentSessionId = agentSessionId
        self.history = history
        self.reply = reply
        self.touchesActivity = touchesActivity
        self.transcript = transcript
    }

    public static func == (a: AgentEventOutcome, b: AgentEventOutcome) -> Bool {
        a.status == b.status && a.notification == b.notification && a.agentSessionId == b.agentSessionId
            && a.history.map(\.role) == b.history.map(\.role) && a.history.map(\.text) == b.history.map(\.text)
            && a.reply == b.reply && a.touchesActivity == b.touchesActivity
            && a.transcript?.conversationId == b.transcript?.conversationId && a.transcript?.path == b.transcript?.path
            && a.permissionRequest == b.permissionRequest && a.backgroundAgents == b.backgroundAgents
    }
}

/// Traduce los eventos de los agentes a cambios de estado. Sin efectos: el store aplica el resultado.
public enum AgentEventInterpreter {
    public static let defaultNotification = "Terminó. Es tu turno."
    public static let permissionNotification = "Necesita tu permiso para seguir."

    /// - Parameter isSubagentThread: si un thread de Codex es de un subagente (sus eventos se ignoran).
    /// - Parameter pendingPermission: la herramienta que pidió permiso, si la sesión sigue esperándolo.
    /// - Parameter inBackground: el agente principal terminó su turno, pero sus subagentes o un
    ///   workflow siguen trabajando (la sesión figura trabajando hasta que Claude retome).
    public static func interpret(_ event: HiveEvent, status: SessionStatus, agentSessionId: String?,
                                 isSubagentThread: (String) -> Bool = { _ in false },
                                 pendingPermission: PermissionRequestKey? = nil,
                                 inBackground: Bool = false) -> AgentEventOutcome {
        var outcome = AgentEventOutcome()
        let payload = event.payload
        // Dentro de un subagente, los hooks traen `agent_id`: no dicen nada del agente principal.
        let fromSubagent = !(payload["agent_id"]?.string ?? "").isEmpty
        // Con el diálogo de permiso abierto, otra herramienta que corría en paralelo puede arrancar o
        // terminar: eso no responde el pedido.
        let otherToolWhileAsking = status == .attention && event.source == "claude"
            && ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(event.name)
            && payload["is_interrupt"]?.asBool != true
            && pendingPermission.map { !$0.matches(payload) } == true
        if otherToolWhileAsking { return outcome }
        switch (event.source, event.name) {
        case ("claude", "SessionStart"):
            // Cambia con /clear: guardamos el nuevo para reanudar la conversación correcta.
            if let id = payload["session_id"]?.string, id != agentSessionId { outcome.agentSessionId = id }
            if let source = payload["source"]?.string, source == "clear" || source == "compact" {
                outcome.history = [(.marker, "/\(source)")]
            }
            outcome.transcript = transcript(payload, agentSessionId: agentSessionId)
        case ("claude", "UserPromptSubmit"):
            outcome.status = .working
            outcome.backgroundAgents = 0
            let source = payload["source"]?.string ?? "user"
            if source == "user" {
                outcome.touchesActivity = true
                if let prompt = payload["prompt"]?.string { outcome.history = [(.user, prompt)] }
            } else if let prompt = payload["prompt"]?.string {
                // Mensajes automáticos (tareas en segundo plano, /loop, recordatorios): no los escribiste vos.
                outcome.history = [(.system, prompt)]
            }
        case ("claude", "PreToolUse"), ("claude", "PostToolUse"):
            // Un subagente usando herramientas solo confirma que sigue trabajando; nunca te saca de tu turno.
            if !fromSubagent || status == .working { outcome.status = .working }
            // El agente principal volvió a trabajar: ya no es solo trabajo en segundo plano.
            if !fromSubagent { outcome.backgroundAgents = 0 }
        case ("claude", "PostToolUseFailure"):
            if payload["is_interrupt"]?.asBool == true {
                // Lo cortaste con Esc: te toca a vos, y ya lo estás mirando.
                if !fromSubagent { outcome.status = .waiting }
            } else if !fromSubagent || status == .working {
                outcome.status = .working
            }
        case ("claude", "PermissionRequest"):
            outcome.status = .attention
            outcome.permissionRequest = PermissionRequestKey(payload: payload)
            outcome.notification = permissionText(toolName: payload["tool_name"]?.string, input: payload["tool_input"],
                                                  cwd: payload["cwd"]?.string)
        case ("claude", "Notification"):
            let type = payload["notification_type"]?.string ?? ""
            let message = payload["message"]?.string ?? ""
            switch notificationEffect(type: type, message: message) {
            case .attention:
                // Si ya pedía permiso (por ejemplo, por PermissionRequest), no hay nada nuevo que avisar.
                guard status != .attention else { break }
                outcome.status = .attention
                outcome.notification = message.isEmpty ? permissionNotification : message
            case .idle:
                // "Claude está esperando tu respuesta" después de un rato sin actividad. Con subagentes o
                // un workflow trabajando en segundo plano todavía no te toca.
                guard status == .working, !inBackground else { break }
                outcome.status = .waiting
                outcome.notification = message.isEmpty ? nil : message
            case .informative:
                break
            }
        case ("claude", "Stop"):
            let full = payload["last_assistant_message"]?.string
            if let full { outcome.history = [(.assistant, full)] }
            outcome.reply = summary(full)
            outcome.touchesActivity = true
            let work = BackgroundWork.parse(payload["background_tasks"])
            outcome.backgroundAgents = work.agents
            if work.agents > 0 {
                // Lanzó subagentes o un workflow en segundo plano: siguen trabajando y Claude retoma solo
                // cuando terminan. Todavía no te toca, así que no hay aviso.
                outcome.status = .working
            } else {
                // Un shell o un monitor en segundo plano (un servidor, por ejemplo) puede no terminar nunca.
                outcome.status = .waiting
                outcome.notification = work.total > 0 ? backgroundText(work.total) : (outcome.reply ?? defaultNotification)
            }
            outcome.transcript = transcript(payload, agentSessionId: agentSessionId)
        case ("claude", "StopFailure"):
            // El turno terminó por un error de la API: sin Stop, así que hace falta que hagas algo.
            let error = errorCode(payload["error"])
            let text = stopFailureText(error)
            if let partial = payload["last_assistant_message"]?.string { outcome.history.append((.assistant, partial)) }
            outcome.history.append((.marker, "\(stopFailureMarker) \(error)"))
            outcome.reply = text
            outcome.touchesActivity = true
            outcome.status = .attention
            outcome.backgroundAgents = 0
            outcome.notification = text
            outcome.transcript = transcript(payload, agentSessionId: agentSessionId)
        case ("codex", _):
            if let thread = payload["thread-id"]?.string, !thread.isEmpty, thread != agentSessionId {
                // Los subagentes de Codex corren con la config del padre: sus avisos no son de esta sesión.
                if isSubagentThread(thread) { return AgentEventOutcome() }
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

    /// Prefijo del marcador que queda en el historial cuando un turno se corta por un error.
    public static let stopFailureMarker = "⚠︎ Se cortó:"

    /// Qué le decimos al usuario según el `error` de StopFailure.
    public static func stopFailureText(_ error: String) -> String {
        switch error {
        case "rate_limit": "Llegaste al límite de uso"
        case "overloaded", "server_error": "Anthropic está saturado: reintentá"
        case "authentication_failed": "Tenés que volver a iniciar sesión (/login)"
        case _ where error.hasPrefix("oauth_"): "Tenés que volver a iniciar sesión (/login)"
        case "max_output_tokens": "La respuesta se cortó (límite de tokens)"
        case "billing_error": "Problema de facturación"
        default: "Se cortó por un error"
        }
    }

    /// Por qué se cortó, para seguir a «Se cortó:» en el historial («llegaste al límite de uso»).
    /// Los mismos códigos que `stopFailureText`; nil si el código no se conoce.
    public static func stopFailureReason(_ error: String) -> String? {
        switch error {
        case "rate_limit": "llegaste al límite de uso"
        case "overloaded", "server_error": "Anthropic está saturado"
        case "authentication_failed": "hay que volver a iniciar sesión (/login)"
        case _ where error.hasPrefix("oauth_"): "hay que volver a iniciar sesión (/login)"
        case "max_output_tokens": "la respuesta llegó al límite de tokens"
        case "billing_error": "hubo un problema de facturación"
        default: nil
        }
    }

    /// El `error` puede venir como texto o, en otras versiones, como objeto con `type`.
    static func errorCode(_ value: JSONValue?) -> String {
        let code = value?.string ?? value?["type"]?.string ?? value?["code"]?.string ?? ""
        return code.isEmpty ? "unknown" : code
    }

    /// Cuántas tareas siguen en segundo plano según `background_tasks` (lista, número u objeto).
    static func backgroundTaskCount(_ value: JSONValue?) -> Int {
        BackgroundWork.parse(value).total
    }

    static func backgroundText(_ count: Int) -> String {
        count == 1 ? "Terminó; queda 1 tarea en segundo plano" : "Terminó; quedan \(count) tareas en segundo plano"
    }

    static func transcript(_ payload: JSONValue, agentSessionId: String?) -> (conversationId: String, path: String)? {
        guard let path = payload["transcript_path"]?.string, !path.isEmpty,
              let id = payload["session_id"]?.string ?? agentSessionId, !id.isEmpty else { return nil }
        return (id, path)
    }

    /// Cuerpo del aviso de PermissionRequest en español: «Pide permiso para Bash: npm test».
    public static func permissionText(toolName: String?, input: JSONValue?, cwd: String? = nil) -> String {
        guard let tool = toolName, !tool.isEmpty else { return permissionNotification }
        func field(_ keys: String...) -> String? {
            for key in keys {
                if let value = input?[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
            }
            return nil
        }
        func file(_ keys: String...) -> String? {
            for key in keys {
                guard let value = input?[key]?.string, !value.isEmpty else { continue }
                return relative(value, to: cwd)
            }
            return nil
        }
        let detail: String?
        switch tool {
        // Estos dos también pasan por el diálogo de permiso, pero no piden permiso para hacer algo.
        case "ExitPlanMode":
            return "Tiene un plan listo para que lo apruebes"
        case "AskUserQuestion":
            let question = input?["questions"]?.array?.first?["question"]?.string
            return question.flatMap { summary($0, limit: 120) }.map { "Te hace una pregunta: \($0)" } ?? "Te hace una pregunta"
        case "Task", "Agent":
            detail = "lanzar un subagente" + (field("description").map { ": \($0)" } ?? "")
        case "Bash":
            detail = field("command").flatMap { summary($0, limit: 120) }.map { "Bash: \($0)" }
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            detail = file("file_path", "notebook_path").map { "editar \($0)" }
        case "Read":
            detail = file("file_path").map { "leer \($0)" }
        case "WebFetch":
            detail = field("url").map { "abrir \($0)" }
        case "WebSearch":
            detail = field("query").map { "buscar en la web «\($0)»" }
        default:
            if tool.hasPrefix("mcp__") {
                // mcp__<servidor>__<herramienta>
                let pieces = tool.dropFirst(5).components(separatedBy: "__")
                detail = pieces.count >= 2 ? "usar \(pieces.dropFirst().joined(separator: "__")) (MCP \(pieces[0]))" : "usar \(tool)"
            } else {
                detail = nil
            }
        }
        return "Pide permiso para " + (detail ?? tool)
    }

    /// Una ruta dentro de la carpeta de la sesión se muestra relativa (app/Models/User.php).
    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// Qué hace un Notification de Claude según su `notification_type`.
    enum NotificationEffect: Equatable {
        /// Necesita que hagas algo (permiso, pregunta de un MCP, un subagente que espera).
        case attention
        /// Terminó y espera tu respuesta: solo cuenta si estaba trabajando.
        case idle
        /// Avisos del sistema que no cambian el estado (un subagente terminó, uso de la compu, cuota…).
        case informative
    }

    static let attentionTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "worker_permission_prompt", "agent_needs_input",
    ]
    static let informativeTypes: Set<String> = [
        "agent_completed", "push_notification", "model_refusal_fallback", "plugin_notification",
    ]
    static let informativePrefixes = ["computer_use_", "quota_", "auth_"]

    static func notificationEffect(type: String, message: String) -> NotificationEffect {
        if attentionTypes.contains(type) { return .attention }
        if type == "idle_prompt" { return .idle }
        if informativeTypes.contains(type) || informativePrefixes.contains(where: { type.hasPrefix($0) }) { return .informative }
        // Tipo desconocido (o versiones viejas sin tipo): la palabra «permission» es el respaldo.
        if message.localizedCaseInsensitiveContains("permission") { return .attention }
        return type.isEmpty ? .idle : .informative
    }

    /// Una línea de hasta 200 caracteres para avisos y tarjetas.
    public static func summary(_ text: String?) -> String? {
        summary(text, limit: 200)
    }

    static func summary(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
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

extension JSONValue {
    /// Booleano de un payload (algunos agentes mandan "true" como texto).
    var asBool: Bool? {
        switch self {
        case .bool(let b): b
        case .string(let s): s == "true" ? true : (s == "false" ? false : nil)
        case .number(let n): n != 0
        default: nil
        }
    }

    /// Número de un payload (también si viene como texto).
    var asDouble: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }
}
