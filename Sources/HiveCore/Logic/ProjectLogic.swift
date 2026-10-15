import Foundation

/// Agrega a un proyecto los worktrees que existen en git pero no en Hive (creados por Warp,
/// Claude, a mano…). Devuelve el proyecto actualizado y las ramas nuevas, o nil si no cambió nada.
public enum WorktreeSync {
    public static func apply(_ worktrees: [GitWorktree], to project: Project,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (project: Project, added: [UUID])? {
        var updated = project
        var added: [UUID] = []
        var changed = false
        for worktree in worktrees {
            guard let name = worktree.branch, !samePath(worktree.path, project.path), exists(worktree.path) else { continue }
            if let i = updated.branches.firstIndex(where: { $0.name == name }) {
                let existing = updated.branches[i]
                if existing.mode == .main {
                    // La rama ahora vive en un worktree creado fuera de Hive.
                    updated.branches[i].mode = .worktree
                    updated.branches[i].worktreePath = worktree.path
                    changed = true
                } else if let path = existing.worktreePath, !samePath(path, worktree.path), !exists(path) {
                    // El worktree se movió (git worktree move).
                    updated.branches[i].worktreePath = worktree.path
                    changed = true
                }
                continue
            }
            if updated.ignoredWorktrees.contains(where: { samePath($0, worktree.path) }) { continue }
            let branch = Branch(name: name, mode: .worktree, worktreePath: worktree.path)
            updated.branches.append(branch)
            added.append(branch.id)
            changed = true
        }
        return changed ? (updated, added) : nil
    }
}

public enum AppearanceDefaults {
    /// El color menos usado por los demás proyectos (en el orden de la paleta).
    public static func color(avoiding used: [TintColor]) -> TintColor {
        TintColor.allCases.min { a, b in
            used.filter { $0 == a }.count < used.filter { $0 == b }.count
        } ?? .blue
    }

    /// Completa color e ícono de un proyecto que no los tiene. `logos` devuelve los logos del repo.
    public static func apply(to project: inout Project, others: [Project], logos: (String) -> [String]) {
        guard !project.isScratch else { return }
        if project.color == nil {
            project.color = color(avoiding: others.filter { $0.id != project.id }.compactMap(\.color))
        }
        if project.icon == nil {
            project.icon = logos(project.path).first.map { .image($0) } ?? .initials
        }
    }
}

/// Pedido de rama nueva o existente desde la hoja "Nueva rama".
public struct NewBranchRequest: Sendable {
    public var projectId: UUID
    public var name: String
    public var isNew: Bool
    public var base: String
    public var mode: BranchMode
    public var firstSession: SessionKind?

    public init(projectId: UUID, name: String, isNew: Bool, base: String = "", mode: BranchMode, firstSession: SessionKind? = nil) {
        self.projectId = projectId
        self.name = name
        self.isNew = isNew
        self.base = base
        self.mode = mode
        self.firstSession = firstSession
    }
}

public enum BranchError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case alreadyInHive(String)
    case invalidName(String)
    case alreadyExists(String)
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Poné el nombre de la rama."
        case .alreadyInHive(let name): "La rama «\(name)» ya está en Hive."
        case .invalidName(let name): "«\(name)» no es un nombre de rama válido."
        case .alreadyExists(let name): "Ya existe una rama «\(name)». Elegí «Rama existente»."
        case .git(let message): message
        }
    }
}

/// Hace el trabajo de git para dejar una rama lista. Bloquea: correrlo fuera del hilo principal.
public enum BranchPlanner {
    public static func prepare(_ request: NewBranchRequest, project: Project, git: GitClient,
                               exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Result<Branch, BranchError> {
        let name = request.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard !project.branches.contains(where: { $0.name == name }) else { return .failure(.alreadyInHive(name)) }

        if request.isNew {
            guard git.isValidBranchName(name, in: project.path) else { return .failure(.invalidName(name)) }
            guard !git.localBranches(project.path).contains(name) else { return .failure(.alreadyExists(name)) }
            let base = request.base.isEmpty ? "HEAD" : request.base
            switch request.mode {
            case .worktree:
                let path = GitParsing.worktreePath(for: name, projectPath: project.path, exists: exists)
                let r = git.addWorktree(at: path, branch: name, newBranch: true, base: base, in: project.path)
                return r.ok ? .success(Branch(name: name, mode: .worktree, worktreePath: path)) : .failure(.git(r.errorMessage))
            case .main:
                let r = git.createBranch(name, from: base, in: project.path)
                return r.ok ? .success(Branch(name: name, mode: .main)) : .failure(.git(r.errorMessage))
            }
        }
        // Rama existente: si ya tiene un worktree, lo adoptamos tal cual.
        if let worktree = git.worktrees(project.path).first(where: { $0.branch == name }) {
            if samePath(worktree.path, project.path) { return .success(Branch(name: name, mode: .main)) }
            return .success(Branch(name: name, mode: .worktree, worktreePath: worktree.path))
        }
        switch request.mode {
        case .worktree:
            let path = GitParsing.worktreePath(for: name, projectPath: project.path, exists: exists)
            let r = git.addWorktree(at: path, branch: name, newBranch: false, base: nil, in: project.path)
            return r.ok ? .success(Branch(name: name, mode: .worktree, worktreePath: path)) : .failure(.git(r.errorMessage))
        case .main:
            // El checkout se hace cuando se abre una sesión en la rama.
            return .success(Branch(name: name, mode: .main))
        }
    }
}
