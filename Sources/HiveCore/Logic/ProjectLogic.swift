import Foundation

/// Mantiene las ramas de un proyecto al día con los worktrees de git: agrega los que existen en git
/// pero no en Hive (creados por Warp, Claude, a mano…) y saca los que se borraron por fuera.
/// Devuelve el proyecto actualizado, las ramas nuevas y las quitadas, o nil si no cambió nada.
/// `isBusy` protege las ramas que todavía tienen una sesión corriendo.
public enum WorktreeSync {
    public static func apply(_ worktrees: [GitWorktree], to project: Project,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                             isBusy: (Branch) -> Bool = { _ in false }) -> (project: Project, added: [UUID], removed: [UUID])? {
        var updated = project
        var added: [UUID] = []
        var removed: [UUID] = []
        var changed = false
        for worktree in worktrees {
            // Los prunable son worktrees borrados por fuera: su carpeta ya no está.
            guard !worktree.isPrunable, let name = worktree.branch, !samePath(worktree.path, project.path), exists(worktree.path) else { continue }
            // Primero por carpeta: si adentro del worktree cambiaron de rama (git checkout -b), es la misma
            // rama de Hive con otro nombre. Se renombra y conserva id, sesiones y color.
            if let i = updated.branches.firstIndex(where: { branch in
                branch.mode == .worktree && branch.worktreePath.map { samePath($0, worktree.path) } == true
            }) {
                if updated.branches[i].name != name && !updated.branches.contains(where: { $0.name == name }) {
                    updated.branches[i].name = name
                    changed = true
                }
                // Si otra rama de Hive ya se llama así, se deja como está: nunca se duplica.
                continue
            }
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
        // Worktrees borrados por fuera (git worktree remove, rm -rf…): la rama se va de Hive. Solo si
        // git respondió (la lista trae la carpeta principal) y el repo está a mano, para no vaciar
        // un proyecto porque git falló o el disco no está montado.
        if worktrees.contains(where: { samePath($0.path, project.path) }), exists(project.path) {
            for branch in updated.branches where branch.mode == .worktree {
                guard let path = branch.worktreePath, !exists(path), !isBusy(branch) else { continue }
                removed.append(branch.id)
            }
            if !removed.isEmpty {
                updated.branches.removeAll { removed.contains($0.id) }
                changed = true
            }
            let ignored = updated.ignoredWorktrees.filter(exists)
            if ignored.count != updated.ignoredWorktrees.count {
                updated.ignoredWorktrees = ignored
                changed = true
            }
        }
        return changed ? (updated, added, removed) : nil
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
    /// Rama o ref de partida (puede ser remota, como "origin/main": la rama nueva no la sigue).
    public var base: String
    public var mode: BranchMode
    public var firstSession: SessionKind?
    /// Rama existente que solo está en un remoto ("upstream/docs"): se crea la local siguiéndolo.
    public var remoteRef: String?
    /// Dónde va la carpeta del worktree.
    public var location: WorktreeLocation
    /// Copiar al worktree los archivos ignorados que necesita (.env, auth.json, permisos de Claude…).
    public var copyIgnored: Bool
    /// Si no es nil, APP_URL del .env copiado (y los dominios que dependían del viejo).
    public var envAppURL: String?
    /// Comando de preparación que el store corre después de crear el worktree.
    public var setupCommand: String?
    public var automaticLaravelSetup: Bool
    public var herd: HerdSites?

    public init(projectId: UUID, name: String, isNew: Bool, base: String = "", mode: BranchMode, firstSession: SessionKind? = nil,
                remoteRef: String? = nil, location: WorktreeLocation = .nested, copyIgnored: Bool = false,
                envAppURL: String? = nil, setupCommand: String? = nil,
                automaticLaravelSetup: Bool = false, herd: HerdSites? = nil) {
        self.projectId = projectId
        self.name = name
        self.isNew = isNew
        self.base = base
        self.mode = mode
        self.firstSession = firstSession
        self.remoteRef = remoteRef
        self.location = location
        self.copyIgnored = copyIgnored
        self.envAppURL = envAppURL
        self.setupCommand = setupCommand
        self.automaticLaravelSetup = automaticLaravelSetup
        self.herd = herd
    }
}

public enum BranchError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case alreadyInHive(String)
    case invalidName(String)
    case alreadyExists(String)
    case noCommits
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Poné el nombre de la rama."
        case .alreadyInHive(let name): "La rama «\(name)» ya está en Hive."
        case .invalidName(let name): "«\(name)» no es un nombre de rama válido."
        case .alreadyExists(let name): "Ya existe una rama «\(name)». Elegí «Rama existente»."
        case .noCommits: "El repo todavía no tiene commits. Creá el primero para poder sumar ramas."
        case .git(let message): message
        }
    }
}

/// Una rama lista, con lo que hizo falta para dejarla así.
public struct PreparedBranch: Equatable, Sendable {
    public var branch: Branch
    /// Archivos ignorados que se copiaron al worktree (rutas relativas).
    public var copiedFiles: [String]
    /// Preparación pedida en la hoja: la corre el store en la carpeta de la rama.
    public var setupCommand: String?
    /// Limpieza del proyecto (polyscope.json o conductor.json) para correr antes de borrar el worktree.
    public var archiveCommand: String?

    public init(branch: Branch, copiedFiles: [String] = [], setupCommand: String? = nil, archiveCommand: String? = nil) {
        self.branch = branch
        self.copiedFiles = copiedFiles
        self.setupCommand = setupCommand
        self.archiveCommand = archiveCommand
    }
}

/// Hace el trabajo de git para dejar una rama lista. Bloquea: correrlo fuera del hilo principal.
public enum BranchPlanner {
    public static func prepare(_ request: NewBranchRequest, project: Project, git: GitClient,
                               exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Result<Branch, BranchError> {
        prepareDetailed(request, project: project, git: git, exists: exists).map(\.branch)
    }

    /// Como `prepare`, y además copia los archivos ignorados al worktree nuevo, reescribe su APP_URL
    /// y devuelve los scripts de preparación y de cierre.
    public static func prepareDetailed(_ request: NewBranchRequest, project: Project, git: GitClient,
                                       exists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                       fileSystem: WorktreeIncludes.FileSystem = .live) -> Result<PreparedBranch, BranchError> {
        let name = request.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure(.emptyName) }
        if let existing = project.branches.first(where: { $0.name == name }),
           request.isNew || request.mode != .worktree || existing.mode == .worktree {
            return .failure(.alreadyInHive(name))
        }
        let trees = git.worktrees(project.path)

        func newPath() -> String {
            GitParsing.worktreePath(for: name, projectPath: project.path, style: request.location, exists: exists)
        }
        /// Un worktree borrado por fuera sigue registrado y bloquea la rama o la carpeta: se olvida esa
        /// entrada sola (un `git worktree prune` también se llevaría los de un disco desconectado).
        func pruneIfNeeded(_ path: String) {
            for stale in trees where stale.isPrunable && (stale.branch == name || samePath(stale.path, path)) {
                _ = git.removeWorktree(stale.path, force: false, in: project.path)
            }
        }
        func worktreeReady(_ path: String) -> PreparedBranch {
            var copied: [String] = []
            var missingCopies: [String] = []
            if request.copyIgnored {
                let files = WorktreeIncludes.files(in: project.path, git: git, fileSystem: fileSystem)
                copied = WorktreeIncludes.copy(files, from: project.path, to: path, fileSystem: fileSystem)
                missingCopies = files.filter { !fileSystem.exists((path as NSString).appendingPathComponent($0)) }
            }
            let automatic = request.automaticLaravelSetup && LaravelWorktreeSetup.detects(project.path, read: fileSystem.read)
            let inheritedEnv = copied.contains(".env")
            let plan = automatic ? LaravelWorktreeSetup.make(projectPath: project.path, worktreePath: path,
                                                              herd: request.herd, read: fileSystem.read, exists: exists) : nil
            var preparationError: String?
            if automatic, !missingCopies.contains(".env"), !fileSystem.exists((path as NSString).appendingPathComponent(".env")),
               let example = fileSystem.read((path as NSString).appendingPathComponent(".env.example")) {
                do {
                    try fileSystem.write(example, (path as NSString).appendingPathComponent(".env"))
                    copied.append(".env")
                } catch { preparationError = "No pude crear .env: \(error.localizedDescription)" }
            }
            let appURL = plan?.url ?? request.envAppURL
            if automatic || (appURL != nil && inheritedEnv) {
                let env = (path as NSString).appendingPathComponent(".env")
                if let text = fileSystem.read(env) {
                    var updated = appURL.map { EnvFile.rewriteAppURL($0, in: text) } ?? text
                    if automatic && inheritedEnv {
                        updated = EnvFile.preserveSQLiteConnection(in: updated, root: project.path, exists: fileSystem.exists)
                    }
                    do { if updated != text { try fileSystem.write(updated, env) } }
                    catch { preparationError = "No pude configurar .env: \(error.localizedDescription)" }
                }
            }
            var setup = plan?.command ?? request.setupCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let preparationError { setup = "printf '%s\\n' \(shellQuote(preparationError)) >&2; exit 1" }
            if !missingCopies.isEmpty {
                let checks = missingCopies.map { file in
                    "test -f \(shellQuote(file)) || { printf '%s\\n' \(shellQuote("No pude copiar \(file). Copialo desde el proyecto principal y reintentá.")) >&2; exit 1; }"
                }
                setup = (checks + [setup ?? ""]).joined(separator: "\n")
            }
            let scripts = ProjectScripts.resolve(projectPath: project.path, folder: (path as NSString).lastPathComponent,
                                                 mainHasCert: false, read: fileSystem.read)
            var branch = Branch(name: name, mode: .worktree, worktreePath: path)
            branch.herdSite = plan?.site
            return PreparedBranch(branch: branch, copiedFiles: copied,
                                  setupCommand: setup?.isEmpty == false ? setup : nil, archiveCommand: scripts.archive?.command)
        }

        if request.isNew {
            guard git.isValidBranchName(name, in: project.path) else { return .failure(.invalidName(name)) }
            let local = git.localBranches(project.path)
            guard !local.contains(name) else { return .failure(.alreadyExists(name)) }
            let base = request.base.isEmpty ? "HEAD" : request.base
            // Sin ramas locales puede ser un repo sin commits… o un HEAD desacoplado, que sí sirve de base.
            if local.isEmpty && base == "HEAD" && git.status(project.path)?.isUnborn == true { return .failure(.noCommits) }
            // Desde una rama remota (origin/main) la rama nueva no la sigue: si no, `git push` iría a main.
            let track: Bool? = base.contains("/") && git.remoteBranches(project.path).contains(base) ? false : nil
            switch request.mode {
            case .worktree:
                let path = newPath()
                pruneIfNeeded(path)
                let r = git.addWorktree(at: path, branch: name, newBranch: true, base: base, track: track, in: project.path)
                return r.ok ? .success(worktreeReady(path)) : .failure(.git(r.errorMessage))
            case .main:
                let r = git.createBranch(name, from: base, track: track, in: project.path)
                return r.ok ? .success(PreparedBranch(branch: Branch(name: name, mode: .main))) : .failure(.git(r.errorMessage))
            }
        }
        // Rama existente: si ya tiene un worktree (que exista), lo adoptamos tal cual.
        if let worktree = trees.first(where: { $0.branch == name && !$0.isPrunable }) {
            if samePath(worktree.path, project.path) { return .success(PreparedBranch(branch: Branch(name: name, mode: .main))) }
            return .success(PreparedBranch(branch: Branch(name: name, mode: .worktree, worktreePath: worktree.path)))
        }
        // Solo remota: se crea la local siguiendo el remoto elegido (con dos remotos, git no sabría cuál).
        let remoteRef = request.remoteRef.flatMap { git.localBranches(project.path).contains(name) ? nil : $0 }
        switch request.mode {
        case .worktree:
            let path = newPath()
            pruneIfNeeded(path)
            let r = remoteRef.map { git.addWorktree(at: path, branch: name, newBranch: true, base: $0, track: true, in: project.path) }
                ?? git.addWorktree(at: path, branch: name, newBranch: false, base: nil, in: project.path)
            return r.ok ? .success(worktreeReady(path)) : .failure(.git(r.errorMessage))
        case .main:
            if let remoteRef {
                let r = git.createBranch(name, from: remoteRef, track: true, in: project.path)
                guard r.ok else { return .failure(.git(r.errorMessage)) }
            }
            // El checkout se hace cuando se abre una sesión en la rama.
            return .success(PreparedBranch(branch: Branch(name: name, mode: .main)))
        }
    }
}
