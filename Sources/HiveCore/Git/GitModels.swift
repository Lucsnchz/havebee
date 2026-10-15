import Foundation

public struct GitChange: Hashable, Identifiable, Sendable {
    /// Código de dos letras de `git status --porcelain` (ej. " M", "A ", "??").
    public let code: String
    public let path: String
    public var id: String { path }

    public init(code: String, path: String) {
        self.code = code
        self.path = path
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

public struct GitStatus: Equatable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [GitChange]

    public init(branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, changes: [GitChange] = []) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
    }

    public var isClean: Bool { changes.isEmpty && ahead == 0 && behind == 0 }
}

public struct GitWorktree: Equatable, Sendable {
    public var path: String
    public var branch: String?

    public init(path: String, branch: String? = nil) {
        self.path = path
        self.branch = branch
    }
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
    public enum Kind: Sendable { case hunk, added, removed, context, note }
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

    public init(lines: [DiffLine] = [], isBinary: Bool = false, truncated: Bool = false, message: String? = nil) {
        self.lines = lines
        self.isBinary = isBinary
        self.truncated = truncated
        self.message = message
    }

    public var addedCount: Int { lines.filter { $0.kind == .added }.count }
    public var removedCount: Int { lines.filter { $0.kind == .removed }.count }
}
