import Foundation

/// Qué tipo de llamada a git es, para elegir cuánto puede tardar antes de cortarla.
public enum GitCallKind: Sendable, Equatable, CaseIterable {
    /// Lecturas y escrituras chicas en el repo (status, log, branch, add…): si tardan, algo se colgó.
    case local
    /// Mueve muchos archivos sin correr hooks (borrar un worktree con su node_modules).
    case bulk
    /// Va por la red sin correr hooks (fetch).
    case network
    /// Puede correr hooks del usuario o filtros como LFS: switch y worktree add (post-checkout),
    /// commit (pre-commit), push (pre-push), pull y merge (post-merge). Una suite de tests en un
    /// pre-push o un composer install en un post-checkout tardan minutos, y cortarlos a mitad de
    /// camino deja el árbol mezclado entre dos ramas o la rama sin publicar.
    case hooks

    /// El tipo de una llamada según sus argumentos (sin los globales `-C` ni `-c`).
    public static func of(_ args: [String]) -> GitCallKind {
        guard let command = args.first else { return .local }
        switch command {
        case "fetch", "ls-remote":
            return .network
        case "push", "pull", "merge", "rebase", "commit", "switch", "cherry-pick", "revert", "am", "clone":
            return .hooks
        case "checkout":
            // `checkout <rama>` corre post-checkout; `checkout --ours -- archivo` solo toca ese archivo.
            return args.contains("--") ? .local : .hooks
        case "worktree":
            switch args.dropFirst().first {
            case "add": return .hooks
            case "remove", "move": return .bulk
            default: return .local
            }
        default:
            return .local
        }
    }
}

/// Cuánto puede tardar cada tipo de llamada a git antes de cortarla (las colgadas vuelven con el
/// status -2). Las que corren hooks tienen un margen muy amplio: no se cortan por tardar unos
/// minutos, y las que van por la red (push, pull) se pueden cancelar desde la UI.
public struct GitTimeouts: Equatable, Sendable {
    public var local: TimeInterval
    public var network: TimeInterval
    public var hooks: TimeInterval

    public init(local: TimeInterval, network: TimeInterval, hooks: TimeInterval) {
        self.local = local
        self.network = network
        self.hooks = hooks
    }

    /// 20 s para lo local, 2 min para la red y media hora para lo que corre hooks.
    public static let standard = GitTimeouts(local: 20, network: 120, hooks: 30 * 60)

    public func limit(for kind: GitCallKind) -> TimeInterval {
        switch kind {
        case .local: local
        case .bulk, .network: network
        // Nunca menos que el de la red: un push también va por la red.
        case .hooks: max(hooks, network)
        }
    }
}
