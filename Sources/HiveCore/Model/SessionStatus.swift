import Foundation

public enum SessionStatus: Equatable, Sendable {
    /// Todavía no se lanzó en esta ejecución de la app.
    case dormant
    /// Proceso corriendo, sin actividad del agente todavía.
    case idle
    case working
    /// El agente terminó su turno: te toca a vos.
    case waiting
    /// El agente necesita permiso o una respuesta para seguir.
    case attention
    case exited(Int32?)

    public func label(for kind: SessionKind) -> String {
        switch self {
        case .dormant: "Dormida"
        case .idle: kind.isAgent ? "Lista" : "Abierta"
        case .working: "Trabajando…"
        case .waiting: "Tu turno"
        case .attention: "Necesita permiso"
        case .exited(let code): code == nil || code == 0 ? "Terminada" : "Terminada (código \(code!))"
        }
    }

    public var isExited: Bool {
        if case .exited = self { return true }
        return false
    }

    /// Estados en los que el agente te espera (se avisa si no lo estás mirando).
    public var needsYou: Bool { self == .waiting || self == .attention }
}
