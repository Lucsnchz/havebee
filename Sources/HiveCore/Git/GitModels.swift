import Foundation

public struct GitChange: Hashable, Identifiable, Sendable {
    /// Código de dos letras de `git status --porcelain` (ej. " M", "A ", "??").
    public let code: String
    public let path: String
    /// Ruta anterior de un archivo renombrado o copiado (`git mv viejo nuevo`).
    public let originalPath: String?
    public var id: String { path }

    public init(code: String, path: String, originalPath: String? = nil) {
        self.code = code
        self.path = path
        self.originalPath = originalPath
    }

    private var index: Character { code.first ?? " " }
    private var worktree: Character { code.count > 1 ? code[code.index(after: code.startIndex)] : " " }

    public var isConflict: Bool { ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(code) }
    public var isUntracked: Bool { code == "??" }
    /// Tiene cambios en el índice (git add).
    public var isStaged: Bool { !isConflict && index != " " && index != "?" }
    /// Tiene cambios sin preparar, está sin seguimiento o en conflicto.
    public var isUnstaged: Bool { isConflict || worktree != " " }

    /// Letra a mostrar en la sección de preparados o de cambios, como en VS Code.
    public func badge(staged: Bool) -> String {
        if isConflict { return "!" }
        if isUntracked { return "U" }
        return String(staged ? index : worktree)
    }

    public var fileName: String { (trimmedPath as NSString).lastPathComponent }
    public var folder: String { (trimmedPath as NSString).deletingLastPathComponent }
    private var trimmedPath: String { path.hasSuffix("/") ? String(path.dropLast()) : path }
}

/// Operación de git a medio terminar en una carpeta (suele quedar así cuando hay conflictos).
public enum GitOperation: String, Sendable, CaseIterable {
    case rebase, merge, cherryPick, revert, bisect

    public var label: String {
        switch self {
        case .rebase: "Rebase a medias"
        case .merge: "Merge a medias"
        case .cherryPick: "Cherry-pick a medias"
        case .revert: "Revert a medias"
        case .bisect: "Bisect a medias"
        }
    }

    /// Para una frase: «con un rebase a medias».
    public var noun: String {
        switch self {
        case .rebase: "rebase"
        case .merge: "merge"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .bisect: "bisect"
        }
    }

    /// En un rebase, «ours» es la rama de destino y «theirs» tu commit: la tuya es «theirs».
    public var swapsOursAndTheirs: Bool { self == .rebase }
}

public struct GitStatus: Equatable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [GitChange]
    /// Commit de HEAD (nil en un repo sin commits o si no se leyó).
    public var headOid: String?
    /// La rama remota de seguimiento ya no existe (se borró al mergear, por ejemplo).
    public var upstreamGone: Bool
    /// Rebase, merge, etc. a medio terminar.
    public var operation: GitOperation?
    /// El repo todavía no tiene commits.
    public var isUnborn: Bool

    public init(branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, changes: [GitChange] = [],
                headOid: String? = nil, upstreamGone: Bool = false, operation: GitOperation? = nil, isUnborn: Bool = false) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.headOid = headOid
        self.upstreamGone = upstreamGone
        self.operation = operation
        self.isUnborn = isUnborn
    }

    public var isClean: Bool { changes.isEmpty && ahead == 0 && behind == 0 }
}

public struct GitWorktree: Equatable, Sendable {
    public var path: String
    public var branch: String?
    /// Su carpeta ya no existe (se borró por fuera): `git worktree prune` lo limpia.
    public var isPrunable: Bool
    /// Bloqueado con `git worktree lock`: para borrarlo hace falta `-f -f`.
    public var isLocked: Bool

    public init(path: String, branch: String? = nil, isPrunable: Bool = false, isLocked: Bool = false) {
        self.path = path
        self.branch = branch
        self.isPrunable = isPrunable
        self.isLocked = isLocked
    }
}

/// Cómo resolver un archivo en conflicto.
public enum ConflictResolution: String, Sendable {
    /// Quedarse con la versión de HEAD (`git checkout --ours`).
    case ours
    /// Quedarse con la versión que se está trayendo (`git checkout --theirs`).
    case theirs
    /// Ya lo resolviste a mano: solo `git add`.
    case markResolved
}

public struct GitCommit: Identifiable, Hashable, Sendable {
    public let hash: String
    public let subject: String
    public let author: String
    public let date: Date
    public var id: String { hash }

    public init(hash: String, subject: String, author: String, date: Date) {
        self.hash = hash
        self.subject = subject
        self.author = author
        self.date = date
    }
}

public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case hunk, added, removed, context, note, conflictMarker }
    public let id: Int
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String

    public init(id: Int, kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct FileDiff: Equatable, Sendable {
    public var lines: [DiffLine]
    public var isBinary: Bool
    public var truncated: Bool
    public var message: String?
    /// El texto tal como lo devolvió git (para copiarlo y pegárselo a la IA).
    public var raw: String
    /// Diff combinado (`diff --cc`) de un archivo en conflicto.
    public var isCombined: Bool

    public init(lines: [DiffLine] = [], isBinary: Bool = false, truncated: Bool = false, message: String? = nil,
                raw: String = "", isCombined: Bool = false) {
        self.lines = lines
        self.isBinary = isBinary
        self.truncated = truncated
        self.message = message
        self.raw = raw
        self.isCombined = isCombined
    }

    public var addedCount: Int { lines.filter { $0.kind == .added }.count }
    public var removedCount: Int { lines.filter { $0.kind == .removed }.count }
}
