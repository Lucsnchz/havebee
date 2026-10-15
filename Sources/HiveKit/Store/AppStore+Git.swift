import AppKit
import HiveCore

/// Proyectos, ramas, checkout y la revisión de git en segundo plano.
extension AppStore {
    // MARK: - Proyectos

    /// ⌘O: elegí una o varias carpetas. Se agregan en orden y queda abierta la última.
    public func addProjectInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Agregar"
        panel.message = "Elegí uno o varios repositorios git (o la carpeta de un worktree)"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { await addProjects(paths) }
    }

    /// Agrega varias carpetas en orden; queda seleccionada la última.
    public func addProjects(_ paths: [String]) async {
        for path in paths { await addProject(at: path) }
    }

    /// Agrega un repo (o lo selecciona si ya está). Si la carpeta es un worktree, agrega o selecciona
    /// el repo principal y abre la rama de ese worktree. Git corre fuera del hilo principal.
    public func addProject(at path: String) async {
        let git = self.git
        let logos = environment.logos
        let lookup = await Task.detached { () -> (found: MainRepoResolver.Found, logos: [String])? in
            guard let found = MainRepoResolver.inspect(path, git: git) else { return nil }
            return (found, logos(found.repo))
        }.value
        guard let lookup else {
            let folder = URL(fileURLWithPath: path).lastPathComponent
            alert = AppAlert(
                title: "No es un repositorio git",
                message: "“\(folder)” no es un repo de git. ¿Querés inicializarlo y agregarlo a Hive?\n\n\(path)",
                actionTitle: "Inicializar git",
                action: { [weak self] in Task { await self?.initializeRepository(at: path) } })
            return
        }
        let found = lookup.found
        if let existing = projects.first(where: { samePath($0.path, found.repo) }) {
            if let worktree = found.worktree {
                openWorktree(worktree.path, in: existing.id, worktrees: found.worktrees)
            } else {
                select(.project(existing.id))
            }
            return
        }
        var project = Project(name: URL(fileURLWithPath: found.repo).lastPathComponent, path: found.repo,
                              branches: found.initialBranch.map { [Branch(name: $0, mode: .main)] } ?? [])
        AppearanceDefaults.apply(to: &project, others: projects, logos: { _ in lookup.logos })
        projects.insertRepo(project)
        gitGeneration += 1
        mainHeads[project.id] = found.head ?? ""
        expanded.formUnion([project.id] + project.branches.map(\.id))
        syncWorktrees(project.id, found.worktrees)
        scheduleSave()
        if let worktree = found.worktree {
            openWorktree(worktree.path, in: project.id, worktrees: found.worktrees)
        } else if let first = project.branches.first {
            select(.branch(first.id))
        } else {
            select(.project(project.id))
        }
        refreshGit()
    }

    /// Elegiste la carpeta de un worktree: lo sumamos si faltaba (aunque lo hubieras quitado antes) y abrimos su rama.
    private func openWorktree(_ path: String, in projectId: UUID, worktrees: [GitWorktree]) {
        projects.updateProject(projectId) { $0.ignoredWorktrees.removeAll { samePath($0, path) } }
        syncWorktrees(projectId, worktrees)
        if let branch = project(projectId)?.branches.first(where: { $0.worktreePath.map { samePath($0, path) } == true }) {
            expanded.formUnion([projectId, branch.id])
            select(.branch(branch.id))
        } else {
            select(.project(projectId))
        }
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
        gitGeneration += 1
        let result = await Task.detached { BranchPlanner.prepare(request, project: project, git: git) }.value
        gitGeneration += 1
        var branch: Branch
        switch result {
        case .success(let value): branch = value
        case .failure(let error): return error.errorDescription
        }
        projects.updateProject(project.id) { p in
            if let path = branch.worktreePath { p.ignoredWorktrees.removeAll { samePath($0, path) } }
            // Una revisión pudo encontrar el worktree nuevo mientras git lo creaba: no lo duplicamos.
            if let i = p.branches.firstIndex(where: { $0.name == branch.name }) {
                p.branches[i].mode = branch.mode
                p.branches[i].worktreePath = branch.worktreePath
                branch = p.branches[i]
            } else {
                p.branches.append(branch)
            }
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
        requestRefresh(onlyWorking: false)
    }

    /// Revisión periódica (cada 10 s): con la app activa revisa todo; en segundo plano, cada 60 s y
    /// solo las carpetas donde hay agentes trabajando.
    func periodicGitRefresh() {
        if environment.isAppActive() {
            refreshGit()
            return
        }
        let now = environment.now()
        guard now.timeIntervalSince(lastBackgroundRefresh) >= 60 else { return }
        lastBackgroundRefresh = now
        requestRefresh(onlyWorking: true)
    }

    private func requestRefresh(onlyWorking: Bool) {
        guard refreshTask == nil else {
            // Una revisión parcial en segundo plano no hace falta repetirla.
            if !onlyWorking { refreshPending = true }
            return
        }
        refreshTask = Task { [weak self] in
            var onlyWorking = onlyWorking
            repeat {
                self?.refreshPending = false
                await self?.refreshGitNow(onlyWorking: onlyWorking)
                onlyWorking = false
            } while self?.refreshPending == true
            self?.refreshTask = nil
        }
    }

    /// Revisa git (estado de cada carpeta, rama de la carpeta principal y worktrees nuevos) y espera.
    /// `onlyWorking`: solo las carpetas con sesiones trabajando, sin buscar worktrees nuevos.
    func refreshGitNow(onlyWorking: Bool = false) async {
        let generation = gitGeneration
        var dirs = gitDirectories()
        var heads = repoProjects.map { ($0.id, $0.path) }
        if onlyWorking {
            let busy = workingDirectories()
            dirs = dirs.intersection(busy)
            heads = heads.filter { busy.contains($0.1) }
            guard !dirs.isEmpty else { return }
        }
        let selected = selectedDormantSession()
        let scan = await GitScan.run(dirs: Array(dirs), heads: heads, worktrees: !onlyWorking, git: git)
        // Fusionamos por clave: lo que se sumó durante la revisión (un proyecto, un worktree) no se pierde.
        var status = dirStatus
        for dir in dirs { status[dir] = scan.statuses[dir] }
        let known = gitDirectories()
        status = status.filter { known.contains($0.key) }
        if dirStatus != status { dirStatus = status }
        var missing = missingWorktrees
        for dir in dirs {
            if scan.missing.contains(dir) { missing.insert(dir) } else { missing.remove(dir) }
        }
        missing = missing.filter { known.contains($0) }
        if missingWorktrees != missing { missingWorktrees = missing }
        // Hive cambió git mientras leíamos: lo leído puede ser viejo. La pasada que pidió ese cambio lo corrige.
        guard generation == gitGeneration else { return }
        var merged = mainHeads
        for (id, head) in scan.heads where project(id) != nil { merged[id] = head }
        merged = merged.filter { project($0.key) != nil }
        if mainHeads != merged {
            let before = mainHeads
            mainHeads = merged
            scheduleSave()
            for (id, head) in merged { warnIfHeadMoved(projectId: id, from: before[id], to: head) }
        }
        // La sesión abierta estaba dormida en una rama inactiva y ahora la rama está activa: la lanzamos.
        if let selected, let ctx = sessionContext(selected), isActive(ctx.branch, in: ctx.project) {
            activate(selected)
        }
        var found = false
        for (id, worktrees) in scan.worktrees where syncWorktrees(id, worktrees) { found = true }
        // Hay ramas nuevas: traemos su estado de git en esta misma pasada.
        if found { await refreshGitNow() }
    }

    /// Algo (vos en una terminal, otra app) cambió la rama de la carpeta principal sin pasar por
    /// Hive. Si la rama de antes tenía sesiones corriendo, ahora están viendo otra: preguntamos.
    private func warnIfHeadMoved(projectId: UUID, from old: String?, to new: String) {
        guard let old, !old.isEmpty, !new.isEmpty, old != new, let project = project(projectId),
              let branch = project.branches.first(where: { $0.mode == .main && $0.name == old }) else { return }
        let running = branch.sessions.filter { runtimes[$0.id]?.isRunning == true }
        guard !running.isEmpty else { return }
        let branchId = branch.id
        let sessions = running.count == 1 ? "La sesión «\(running[0].name)» quedó" : "Las \(running.count) sesiones de esa rama quedaron"
        alert = AppAlert(title: "Algo cambió la carpeta principal de “\(old)” a “\(new)”",
                         message: "\(sessions) viendo «\(new)» en «\(project.name)». ¿Las movés a esa rama en Hive?",
                         actionTitle: "Mover las sesiones ahí", cancelTitle: "Dejar así",
                         action: { [weak self] in self?.followHead(branchId: branchId, to: new) })
    }

    /// «Mover las sesiones ahí»: si Hive no tiene una rama con ese nombre, la rama se renombra;
    /// si la tiene, le pasamos las sesiones que estaban corriendo.
    func followHead(branchId: UUID, to name: String) {
        guard let ctx = branchContext(branchId) else { return }
        if let target = ctx.project.branches.first(where: { $0.name == name && $0.id != branchId }) {
            let moving = Set(ctx.branch.sessions.filter { runtimes[$0.id]?.isRunning == true }.map(\.id))
            projects.updateProject(ctx.project.id) { p in
                guard let from = p.branches.firstIndex(where: { $0.id == branchId }),
                      let to = p.branches.firstIndex(where: { $0.id == target.id }) else { return }
                p.branches[to].sessions += p.branches[from].sessions.filter { moving.contains($0.id) }
                p.branches[from].sessions.removeAll { moving.contains($0.id) }
            }
            expanded.formUnion([ctx.project.id, target.id])
            if selection == .branch(branchId) { select(.branch(target.id)) }
        } else {
            projects.updateBranch(branchId) { $0.name = name }
        }
        scheduleSave()
    }

    /// La sesión abierta, si está dormida porque su rama no está activa.
    private func selectedDormantSession() -> UUID? {
        guard case .session(let id)? = selection, let ctx = sessionContext(id), runtimes[id]?.status == .dormant,
              !isActive(ctx.branch, in: ctx.project) else { return nil }
        return id
    }

    /// Carpetas con algún agente trabajando.
    func workingDirectories() -> Set<String> {
        var dirs = Set<String>()
        for p in repoProjects {
            for b in p.branches where b.sessions.contains(where: { runtimes[$0.id]?.status == .working }) {
                dirs.insert(p.directory(for: b))
            }
        }
        return dirs
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

/// Lo que leyó una revisión de git.
private struct GitScan: Sendable {
    var statuses: [String: GitStatus] = [:]
    var heads: [UUID: String] = [:]
    var worktrees: [UUID: [GitWorktree]] = [:]
    /// Carpetas que no existen.
    var missing: Set<String> = []

    private enum Job: Sendable {
        case status(String)
        case head(UUID, String)
    }

    private enum Outcome: Sendable {
        case status(String, GitStatus?, exists: Bool)
        case head(UUID, String, [GitWorktree]?)
    }

    /// Corre git en paralelo, como mucho `width` llamadas a la vez (cada una ocupa un hilo mientras espera).
    static func run(dirs: [String], heads: [(UUID, String)], worktrees: Bool, git: GitClient, width: Int = 4) async -> GitScan {
        let jobs = dirs.map(Job.status) + heads.map { Job.head($0.0, $0.1) }
        return await withTaskGroup(of: Outcome.self, returning: GitScan.self) { group in
            var next = 0
            func perform(_ job: Job) -> Outcome {
                switch job {
                case .status(let dir):
                    guard FileManager.default.fileExists(atPath: dir) else { return .status(dir, nil, exists: false) }
                    return .status(dir, git.status(dir), exists: true)
                case .head(let id, let path):
                    return .head(id, git.currentBranch(path) ?? "", worktrees ? git.worktrees(path) : nil)
                }
            }
            while next < min(width, jobs.count) {
                let job = jobs[next]
                group.addTask(priority: .utility) { perform(job) }
                next += 1
            }
            var scan = GitScan()
            while let outcome = await group.next() {
                switch outcome {
                case .status(let dir, let status, let exists):
                    scan.statuses[dir] = status
                    if !exists { scan.missing.insert(dir) }
                case .head(let id, let head, let trees):
                    scan.heads[id] = head
                    if let trees { scan.worktrees[id] = trees }
                }
                if next < jobs.count {
                    let job = jobs[next]
                    group.addTask(priority: .utility) { perform(job) }
                    next += 1
                }
            }
            return scan
        }
    }
}
