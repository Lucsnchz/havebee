import Foundation

/// Lo que sigue corriendo cuando Claude termina su turno: el `background_tasks` del hook Stop.
/// Cada tarea trae su `type` ("subagent", "workflow", "shell", "monitor"… o el nombre interno si
/// Claude no tiene uno amigable) y su `status`.
public struct BackgroundWork: Equatable, Sendable {
    /// Subagentes y workflows: siguen trabajando y despiertan a la sesión cuando terminan.
    public var agents: Int
    /// Lo demás (shells, monitores, tareas de MCP): un servidor o un monitor puede no terminar nunca.
    public var others: Int

    public init(agents: Int = 0, others: Int = 0) {
        self.agents = agents
        self.others = others
    }

    public var total: Int { agents + others }

    /// Lee `background_tasks`: una lista de tareas (lo que manda Claude 2.1), un objeto con las tareas
    /// como valores o, en versiones viejas, solo la cantidad.
    public static func parse(_ value: JSONValue?) -> BackgroundWork {
        switch value {
        case .array(let tasks)?:
            return tally(tasks)
        case .object(let tasks)?:
            return tally(Array(tasks.values))
        // Int(n) se cae con un número fuera de rango: el payload viene de afuera.
        case .number(let n)?:
            return BackgroundWork(others: n.isFinite ? Int(min(max(n, 0), 10_000)) : 0)
        default:
            return BackgroundWork()
        }
    }

    private static func tally(_ tasks: [JSONValue]) -> BackgroundWork {
        var work = BackgroundWork()
        for task in tasks.prefix(10_000) where !isFinished(task["status"]?.string) {
            if isAgent(type: task["type"]?.string) { work.agents += 1 } else { work.others += 1 }
        }
        return work
    }

    /// Un subagente, un workflow o un compañero de equipo (también con los nombres internos de Claude,
    /// como "local_agent" o "local_workflow"). Sin tipo no se sabe: cuenta como otra tarea.
    static func isAgent(type: String?) -> Bool {
        guard let type = type?.lowercased(), !type.isEmpty else { return false }
        return ["agent", "workflow", "teammate"].contains { type.contains($0) }
    }

    /// Claude manda solo lo que está en curso, pero por las dudas no contamos lo que ya terminó.
    static func isFinished(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return ["completed", "failed", "killed", "stopped", "cancelled", "canceled"].contains(status)
    }
}

/// Respaldo para una sesión que quedó trabajando en segundo plano: si no llega ningún evento suyo
/// (ni de sus subagentes) durante un buen rato, dejamos de mostrarla trabajando. Normalmente no hace
/// falta: cuando las tareas terminan, Claude retoma solo y su Stop deja la sesión esperándote.
public enum BackgroundRule {
    /// Un comando largo de un subagente puede tardar hasta 10 minutos sin mandar eventos.
    public static let quiet: TimeInterval = 15 * 60

    public static func expired(now: Date, lastEvent: Date) -> Bool {
        now.timeIntervalSince(lastEvent) > quiet
    }

    public static let expiredNotification = "Las tareas en segundo plano no dan señales hace 15 minutos."
}
