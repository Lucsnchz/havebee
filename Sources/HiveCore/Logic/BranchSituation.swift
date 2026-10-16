import Foundation

/// En qué situación está una rama, para que el encabezado, la tarjeta, el aviso y las acciones de la
/// vista de rama digan lo mismo y no se ofrezca nada que no va a andar.
public enum BranchSituation: Equatable, Sendable {
    /// Un worktree con su carpeta.
    case worktree
    /// Tiene el checkout en la carpeta principal.
    case main
    /// Es de la carpeta principal, pero la carpeta está en otra rama: hace falta un checkout.
    case inactive
    /// Como `inactive`, pero la carpeta principal tiene un rebase o un merge a medias: git no deja
    /// hacer checkout hasta que se termine o se cancele.
    case blocked
    /// La carpeta del worktree se borró o se movió por fuera de Hive.
    case missing

    /// - Parameters:
    ///   - active: la rama tiene checkout (los worktrees siempre lo tienen).
    ///   - missing: la revisión de git no encontró la carpeta del worktree.
    ///   - mainBusy: la carpeta principal tiene una operación de git a medias.
    public static func of(mode: BranchMode, active: Bool, missing: Bool, mainBusy: Bool) -> BranchSituation {
        if mode == .worktree { return missing ? .missing : .worktree }
        if active { return .main }
        return mainBusy ? .blocked : .inactive
    }

    /// Lo que dicen el chip del encabezado y la tarjeta de la rama.
    public var label: String {
        switch self {
        case .worktree: "Worktree"
        case .main: "Carpeta principal"
        case .inactive, .blocked: "Inactiva"
        case .missing: "Sin carpeta"
        }
    }

    /// Se muestra en naranja: hay algo que resolver antes de trabajar en la rama.
    public var isWarning: Bool { self == .missing }

    /// Tiene la rama en disco: los comandos, el sitio y los cambios son de esta rama.
    public var hasCheckout: Bool { self == .worktree || self == .main }

    /// Se le pueden crear sesiones (en una inactiva, Hive pide el checkout primero).
    public var canStartSessions: Bool { self != .blocked && self != .missing }

    /// La carpeta existe, así que se puede abrir en otra app (aunque tenga otra rama).
    public var hasFolder: Bool { self != .missing }

    /// Se le puede publicar la rama o abrir el MR (traer cambios ya lo resuelve el menú del remoto).
    public var offersRemoteActions: Bool { self != .missing }
}
