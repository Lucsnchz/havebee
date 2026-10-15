import AppKit
import HiveCore

/// Proyectos, ramas, checkout y la revisión de git en segundo plano.
extension AppStore {
    // MARK: - Proyectos

    public func addProjectInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Agregar"
        panel.message = "Elegí la carpeta de un repositorio git"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addProject(at: url.path) }
    }

    /// Agrega un repo (o lo selecciona si ya está). Git corre fuera del hilo principal.
    public func addProject(at path: String) async {
        let git = self.git
        let found = await Task.detached { () -> (top: String, head: String?, worktrees: [GitWorktree])? in
            guard let top = git.topLevel(path) else { return nil }
            return (top, git.currentBranch(top), git.worktrees(top))
        }.value
        guard let found else {
            alert = AppAlert(
                title: "No es un repositorio git",
                message: "\(path)\n\n¿Querés inicializar git en esta carpeta?",
                actionTitle: "Inicializar git",
                action: { [weak self] in Task { await self?.initializeRepository(at: path) } })
            return
        }
        if let existing = projects.first(where: { samePath($0.path, found.top) }) {
            select(.project(existing.id))
            return
        }
        var project = Project(name: URL(fileURLWithPath: found.top).lastPathComponent, path: found.top,
                              branches: [Branch(name: found.head ?? "HEAD", mode: .main)])
        AppearanceDefaults.apply(to: &project, others: projects, logos: environment.logos)
        projects.insertRepo(project)
        gitGeneration += 1
        mainHeads[project.id] = found.head ?? ""
        expanded.formUnion([project.id, project.branches[0].id])
        syncWorktrees(project.id, found.worktrees)
        scheduleSave()
        select(.branch(project.branches[0].id))
        refreshGit()
    }

    func initializeRepository(at path: String) async {
        let git = self.git
        let r = await Task.detached { git.initRepository(path) }.value
        if r.ok { await addProject(at: path) } else { alert = AppAlert(title: "No se pudo inicializar git", message: r.errorMessage) }
    }

    /// Suma los worktrees que existen en git pero no en Hive. Devuelve si cambió algo.
    @discardableResult
    func syncWorktrees(_ projectId: UUID, _ worktrees: [GitWorktree]) -> Bool {
        guard let project = project(projectId), let result = WorktreeSync.apply(worktrees, to: project) else { return false }
        projects.updateProject(projectId) { $0 = result.project }
        expanded.formUnion(result.added)
        scheduleSave()
        return true
    }

    // MARK: - Ramas

    /// Crea o agrega una rama. Devuelve el error a mostrar, o nil si salió bien.
    public func createBranch(_ request: NewBranchRequest) async -> String? {
        guard let project = project(request.projectId) else { return "No encontré el proyecto." }
        let git = self.git
        let result = await Task.detached { BranchPlanner.prepare(request, project: project, git: git) }.value
        let branch: Branch
        switch result {
        case .success(let value): branch = value
        case .failure(let error): return error.errorDescription
        }
        gitGeneration += 1
        projects.updateProject(project.id) { p in
            p.branches.append(branch)
            if let path = branch.worktreePath { p.ignoredWorktrees.removeAll { samePath($0, path) } }
        }
        expanded.formUnion([project.id, branch.id])
        scheduleSave()
        select(.branch(branch.id))
        refreshGit()
        if let kind = request.firstSession { requestNewSession(branchId: branch.id, kind: kind) }
        return nil
    }

    public func requestCheckout(branchId: UUID, then after: AfterCheckout = .nothing) {
        guard let ctx = branchContext(branchId) else { return }
        let others = ctx.project.branches
            .filter { $0.mode == .main && $0.id != branchId }
            .flatMap(\.sessions)
            .filter { runtimes[$0.id]?.isRunning == true }
            .count
        let dirty = !(dirStatus[ctx.project.path]?.changes.isEmpty ?? true)
        pendingCheckout = PendingCheckout(branchId: branchId, branchName: ctx.branch.name, currentHead: mainHead(of: ctx.project.id),
                                          after: after, runningElsewhere: others, dirty: dirty)
    }

    public func confirmCheckout(_ pending: PendingCheckout) {
        Task { await performCheckout(pending) }
    }

    /// Hace el checkout y lo que se pidió después. Devuelve si salió bien.
    @discardableResult
    func performCheckout(_ pending: PendingCheckout) async -> Bool {
        guard let ctx = branchContext(pending.branchId) else { return false }
        let path = ctx.project.path
        let name = ctx.branch.name
        let git = self.git
        gitGeneration += 1
        let r = await Task.detached { git.checkout(name, in: path) }.value
        // Otra vez: una revisión que empezó durante el checkout pudo leer la rama de antes.
        gitGeneration += 1
        guard r.ok else {
            alert = AppAlert(title: "No se pudo hacer checkout de «\(name)»", message: r.errorMessage)
            return false
        }
        mainHeads[ctx.project.id] = name
        refreshGit()
        switch pending.after {
        case .createSession(let kind): createSession(branchId: pending.branchId, kind: kind)
        case .openSession(let id):
            select(.session(id))
            activate(id)
        case .nothing: break
        }
        return true
    }

    // MARK: - Git

    /// Pide una revisión de git en segundo plano. Corre una a la vez; si llega un pedido con una
    /// pasada en curso, no se pierde: al terminar se hace otra.
    public func refreshGit() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            repeat {
                self?.refreshPending = false
                await self?.refreshGitNow()
            } while self?.refreshPending == true
            self?.refreshTask = nil
        }
    }

    /// Revisa git (estado de cada carpeta, rama de la carpeta principal y worktrees nuevos) y espera.
    func refreshGitNow() async {
        let generation = gitGeneration
        let dirs = gitDirectories()
        let heads = repoProjects.map { ($0.id, $0.path) }
        let git = self.git
        let (statuses, current, trees) = await Task.detached(priority: .utility) {
            var statuses: [String: GitStatus] = [:]
            for dir in dirs { if let s = git.status(dir) { statuses[dir] = s } }
            var current: [UUID: String] = [:]
            var trees: [UUID: [GitWorktree]] = [:]
            for (id, path) in heads {
                current[id] = git.currentBranch(path) ?? ""
                trees[id] = git.worktrees(path)
            }
            return (statuses, current, trees)
        }.value
        // Fusionamos por clave: lo que se sumó durante la revisión (un proyecto, un worktree) no se pierde.
        var status = dirStatus
        for dir in dirs { status[dir] = statuses[dir] }
        let known = gitDirectories()
        status = status.filter { known.contains($0.key) }
        if dirStatus != status { dirStatus = status }
        // Hive cambió git mientras leíamos: lo leído puede ser viejo. La pasada que pidió ese cambio lo corrige.
        guard generation == gitGeneration else { return }
        var merged = mainHeads
        for (id, head) in current where project(id) != nil { merged[id] = head }
        merged = merged.filter { project($0.key) != nil }
        if mainHeads != merged { mainHeads = merged }
        var found = false
        for (id, worktrees) in trees where syncWorktrees(id, worktrees) { found = true }
        // Hay ramas nuevas: traemos su estado de git en esta misma pasada.
        if found { await refreshGitNow() }
    }

    /// Carpetas de las que se guarda el estado de git: la principal de cada repo y cada worktree.
    func gitDirectories() -> Set<String> {
        var dirs = Set<String>()
        for p in repoProjects {
            dirs.insert(p.path)
            for b in p.branches where b.mode == .worktree { if let path = b.worktreePath { dirs.insert(path) } }
        }
        return dirs
    }
}
