import Foundation

/// Lo que corta el proceso de una sesión.
public enum SessionInterruption: Sendable, CaseIterable {
    /// Archivarla (⌘W, la X de la pestaña, «Archivar»).
    case archive
    /// Reiniciarla (⌘R, «Reiniciar»).
    case restart
    /// Detenerla (⌘., «Detener»).
    case stop
}

/// El diálogo que pide confirmar antes de cortar algo que está en curso.
public struct InterruptConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    /// «Archivar igual», «Reiniciar igual» o «Detener igual».
    public let actionTitle: String
}

/// Cuándo hay que preguntar antes de cortar una sesión. Es una sola regla para el menú «Sesión», el
/// sidebar, las pestañas de la vista compacta, la barra de la sesión y los atajos (⌘W, ⌘R y ⌘.).
public enum InterruptRule {
    /// Pregunta si cortarla rompe algo en curso: un agente que trabaja o que espera permiso (en los dos
    /// casos está a mitad de una herramienta), o una Terminal con un proceso en primer plano que no es
    /// el shell esperando en el prompt (`npm run dev`, un build, un `composer install`).
    /// `foregroundJob`: el nombre de ese proceso ("" si no se sabe), o nil si no hay ninguno.
    public static func needsConfirmation(status: SessionStatus, isAgent: Bool, foregroundJob: String?) -> Bool {
        if status.isExited || status == .dormant { return false }
        if isAgent { return status == .working || status == .attention }
        return foregroundJob != nil
    }

    /// El diálogo para confirmar `action`, o nil si se puede cortar sin preguntar.
    public static func confirmation(for action: SessionInterruption, sessionName name: String, isAgent: Bool,
                                    status: SessionStatus, foregroundJob: String?) -> InterruptConfirmation? {
        guard needsConfirmation(status: status, isAgent: isAgent, foregroundJob: foregroundJob) else { return nil }
        let actionTitle = switch action {
        case .archive: "Archivar igual"
        case .restart: "Reiniciar igual"
        case .stop: "Detener igual"
        }
        if isAgent {
            let verb = switch action {
            case .archive: "la archivás"
            case .restart: "la reiniciás"
            case .stop: "la detenés"
            }
            let attention = status == .attention
            let what = attention
                ? "Está esperando tu permiso a mitad de lo que estaba haciendo. Si \(verb), se corta."
                : "Si \(verb), se corta lo que está haciendo."
            let saved = switch action {
            case .archive: "La conversación queda guardada y la podés restaurar."
            case .restart: "La conversación queda guardada y se retoma al arrancar."
            case .stop: "La conversación queda guardada y la podés reanudar."
            }
            // ⌘. y ⌘R son reflejos («cancelar», «recargar»): lo que casi siempre se quiere es frenar el turno.
            let tip = action == .archive ? nil : "Para frenar solo este turno, apretá Esc en la terminal."
            return InterruptConfirmation(title: attention ? "«\(name)» necesita permiso" : "«\(name)» está trabajando",
                                         message: [what, saved, tip].compactMap { $0 }.joined(separator: " "),
                                         actionTitle: actionTitle)
        }
        let job = foregroundJob ?? ""
        let title = job.isEmpty ? "Hay un proceso corriendo en «\(name)»" : "«\(job)» está corriendo en «\(name)»"
        let message = switch action {
        case .archive: "Si la archivás, se corta. «Deshacer» devuelve la pestaña, pero no el proceso."
        case .restart: "Si reiniciás la terminal, se corta."
        case .stop: "Si la detenés, se corta junto con la terminal."
        }
        return InterruptConfirmation(title: title, message: message, actionTitle: actionTitle)
    }
}
