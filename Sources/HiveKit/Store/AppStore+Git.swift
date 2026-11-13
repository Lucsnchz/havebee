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
                message: "«\(folder)» no es un repo de git. ¿Querés inicializarlo y agregarlo a Havebee?\n\n\(path)",
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
        confirmedHeads.insert(project.id)
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
        if r.ok { await addProject(at: path) } else { alert = AppAlert(title: "No pude inicializar git", message: r.errorMessage) }
    }

    /// Suma los worktrees que existen en git pero no en Hive y saca los que se borraron por fuera
    /// (salvo que tengan una sesión o un comando corriendo: esas quedan marcadas como faltantes
    /// hasta que terminen). Devuelve si cambió algo.
    @discardableResult
    func syncWorktrees(_ projectId: UUID, _ worktrees: [GitWorktree]) -> Bool {
        guard let project = project(projectId),
              let result = WorktreeSync.apply(worktrees, to: project, isBusy: { hasRunningWork($0) }) else { return false }
        let gone = project.branches.filter { result.removed.contains($0.id) }
        let selectionWasInside = gone.contains { branch in
            selection == .branch(branch.id) || branch.sessions.contains { selection == .session($0.id) }
        }
        terminate(gone.flatMap { $0.sessions.map(\.id) })
        // Los comandos que quedan ya terminaron (si no, la rama no se iba): se cierran con su rama.
        stopRuns { run in gone.contains { $0.id == run.branchId } }
        projects.updateProject(projectId) { $0 = result.project }
        expanded.formUnion(result.added)
        expanded.subtract(result.removed)
        missingWorktrees.subtract(gone.compactMap(\.worktreePath))
        if selectionWasInside { select(.project(projectId)) }
        scheduleSave()
        return true
    }

    /// Hay una sesión o un comando corriendo en la rama: no se la saca de Hive por su cuenta.
    func hasRunningWork(_ branch: Branch) -> Bool {
        branch.sessions.contains { runtimes[$0.id]?.isRunning == true }
            || commandRuns.contains { $0.branchId == branch.id && $0.running }
    }

    // MARK: - Ramas

    /// Crea o agrega una rama. Devuelve el error a mostrar, o nil si salió bien. En un worktree nuevo
    /// copia los archivos ignorados que necesita (si se pidió), corre la preparación en la esquinita
    /// y avisa qué copió.
    public func createBranch(_ request: NewBranchRequest) async -> String? {
        guard let project = project(request.projectId) else { return "No encontré el proyecto." }
        if let existing = project.branches.first(where: { $0.name == request.name }), hasRunningWork(existing) {
            return "Cerrá las sesiones y comandos de esta rama antes de crear su worktree."
        }
        let git = self.git
        gitGeneration += 1
        gitOperations += 1
        let herdRoot = HerdSites.defaultRoot(home: environment.home)
        let result = await Task.detached {
            var request = request
            if request.herd != nil { request.herd = HerdSites.parse(configRoot: herdRoot) }
            return BranchPlanner.prepareDetailed(request, project: project, git: git)
        }.value
        gitOperations -= 1
        gitGeneration += 1
        let prepared: PreparedBranch
        switch result {
        case .success(let value): prepared = value
        case .failure(let error):
            // La revisión que corría mientras tanto se descartó: que venga otra.
            refreshGit()
            return error.errorDescription
        }
        var branch = prepared.branch
        branch.setupCommand = prepared.setupCommand
        branch.setupFirstSession = prepared.setupCommand == nil ? nil : request.firstSession
        projects.updateProject(project.id) { p in
            if let path = branch.worktreePath { p.ignoredWorktrees.removeAll { samePath($0, path) } }
            // Una revisión pudo encontrar el worktree nuevo mientras git lo creaba: no lo duplicamos.
            if let i = p.branches.firstIndex(where: { $0.name == branch.name }) {
                p.branches[i].mode = branch.mode
                p.branches[i].worktreePath = branch.worktreePath
                p.branches[i].setupCommand = branch.setupCommand
                p.branches[i].setupFirstSession = branch.setupFirstSession
                p.branches[i].herdSite = branch.herdSite
                p.branches[i].ownDatabase = branch.ownDatabase
                branch = p.branches[i]
            } else {
                p.branches.append(branch)
            }
        }
        expanded.formUnion([project.id, branch.id])
        scheduleSave()
        select(.branch(branch.id))
        refreshGit()
        // setupCommand nil: la casilla «Preparar» estaba apagada.
        if prepared.setupCommand != nil { retryPreparation(branch.id) }
        if !prepared.copiedFiles.isEmpty {
            showNotice("Copié \(WorktreeIncludes.summary(prepared.copiedFiles)) a «\(branch.name)»")
        }
        if prepared.setupCommand == nil, let kind = request.firstSession { requestNewSession(branchId: branch.id, kind: kind) }
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
        gitOperations += 1
        let r = await Task.detached { git.checkout(name, in: path) }.value
        gitOperations -= 1
        // Otra vez: una revisión que empezó durante el checkout pudo leer la rama de antes.
        gitGeneration += 1
        guard r.ok else {
            alert = AppAlert(title: "No pude hacer checkout de «\(name)»", message: r.errorMessage)
            // La revisión que corría mientras tanto se descartó: que venga otra.
            refreshGit()
            return false
        }
        mainHeads[ctx.project.id] = name
        confirmedHeads.insert(ctx.project.id)
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

    /// Un repo sin commits: crea un commit vacío («Primer commit») para poder crear ramas. Devuelve el
    /// error de git, o nil si salió bien.
    @discardableResult
    public func createFirstCommit(projectId: UUID) async -> String? {
        guard let project = project(projectId) else { return "No encontré el proyecto." }
        let git = self.git
        let path = project.path
        let r = await Task.detached { git.commitAllowEmpty(message: "Primer commit", in: path) }.value
        guard r.ok else {
            alert = AppAlert(title: "No pude crear el primer commit", message: r.errorMessage)
            return r.errorMessage
        }
        refreshGit()
        return nil
    }

    /// Pide una revisión de git completa en segundo plano: después de que Hive cambió git, o cuando
    /// hace falta todo al día sin esperar los avisos de macOS. Corre una a la vez; si llega un pedido
    /// con una pasada en curso, no se pierde: al terminar se hace otra.
    public func refreshGit() {
        requestRefresh(.all)
    }

    /// Pide leer de git solo lo que cambió desde la última revisión (ver `GitStaleness`).
    public func refreshGitChanges() {
        requestRefresh(.changed)
    }

    /// Cada cuánto se lee todo igual, con la app activa, por si macOS no avisó algún cambio (en un
    /// disco de red no avisa los que vienen de otra máquina).
    static let fullGitRefreshInterval: TimeInterval = 300

    /// Revisión periódica (cada 10 s): con la app activa lee lo que cambió, y todo cada 5 minutos; en
    /// segundo plano, cada 60 s y solo lo que cambió en las carpetas donde hay agentes trabajando.
    func periodicGitRefresh() {
        let now = environment.now()
        if environment.isAppActive() {
            requestRefresh(now.timeIntervalSince(lastFullGitRefresh) >= Self.fullGitRefreshInterval ? .all : .changed)
            return
        }
        guard now.timeIntervalSince(lastBackgroundRefresh) >= 60 else { return }
        lastBackgroundRefresh = now
        requestRefresh(.working)
    }

    private func requestRefresh(_ scope: GitRefreshScope) {
        guard refreshTask == nil else {
            // Una revisión parcial en segundo plano no hace falta repetirla.
            if scope > .working { refreshPending = max(refreshPending ?? scope, scope) }
            return
        }
        refreshTask = Task { [weak self] in
            var next: GitRefreshScope? = scope
            while let scope = next {
                self?.refreshPending = nil
                await self?.refreshGitNow(scope)
                next = self?.refreshPending
            }
            self?.refreshTask = nil
        }
    }

    /// Revisa git (estado de cada carpeta, rama de la carpeta principal y worktrees nuevos) y espera.
    func refreshGitNow(_ scope: GitRefreshScope = .all) async {
        let generation = gitGeneration
        // Primero se anota lo que avisó macOS: lo que cambie mientras se lee lo anota la próxima.
        let layout = gitLayout()
        environment.directories.watch(layout.roots)
        staleGit.record(environment.directories.drain(), in: layout)
        var dirs = gitDirectories()
        var heads = repoProjects.map { ($0.id, $0.path) }
        if scope == .all {
            lastFullGitRefresh = environment.now()
        } else {
            dirs = dirs.intersection(staleGit.statuses)
            heads = heads.filter { staleGit.repositories.contains($0.1) }
        }
        if scope == .working {
            let busy = workingDirectories()
            dirs = dirs.intersection(busy)
            heads = heads.filter { busy.contains($0.1) }
        }
        if scope != .all {
            guard !dirs.isEmpty || !heads.isEmpty else { return }
        }
        // En segundo plano se lee la rama pero no las ramas ni los worktrees: el repo sigue pendiente.
        staleGit.clear(statuses: dirs, repositories: scope == .working ? [] : heads.map(\.1))
        let scan = await GitScan.run(dirs: Array(dirs), heads: heads, worktrees: scope != .working, git: git)
        // git no pudo leer una carpeta que existe (tardó demasiado, por ejemplo): se reintenta en la próxima.
        for dir in dirs where scan.statuses[dir] == nil && !scan.missing.contains(dir) { staleGit.markStatus(dir) }
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
        // Hive cambió git mientras leíamos (o lo está cambiando ahora): lo leído puede ser viejo o estar a
        // mitad de camino. La pasada que pide ese cambio al terminar lo corrige.
        guard generation == gitGeneration, gitOperations == 0 else {
            if scope != .working { for (_, path) in heads { staleGit.markRepository(path) } }
            return
        }
        applyHeads(scan.heads)
        for (id, branches) in scan.branches where repositoryBranches[id] != branches { repositoryBranches[id] = branches }
        var found = false
        for (id, worktrees) in scan.worktrees where syncWorktrees(id, worktrees) { found = true }
        // Hay ramas nuevas: traemos su estado de git en esta misma pasada.
        if found { await refreshGitNow() }
    }

    /// Al arrancar, antes de la revisión completa: lee solo la rama de cada carpeta principal (no mira
    /// los archivos, así que es rápido aunque `git status` tarde) para confirmar la guardada y lanzar
    /// enseguida la sesión que tenés abierta.
    func confirmSavedHeads() async {
        let pending = repoProjects.filter { !confirmedHeads.contains($0.id) }.map { ($0.id, $0.path) }
        guard !pending.isEmpty else { return }
        let generation = gitGeneration
        let git = self.git
        let heads = await Task.detached(priority: .userInitiated) { () -> [UUID: String] in
            var heads: [UUID: String] = [:]
            for (id, path) in pending { heads[id] = git.currentBranch(path) ?? "" }
            return heads
        }.value
        // Hive cambió git mientras tanto (o lo está cambiando): lo leído puede ser viejo; lo corrige la revisión completa.
        guard generation == gitGeneration, gitOperations == 0 else { return }
        applyHeads(heads)
    }

    /// Aplica la rama leída de cada carpeta principal: la da por confirmada, avisa si cambió por fuera
    /// con sesiones corriendo y lanza las sesiones abiertas que esperaban saberla.
    private func applyHeads(_ heads: [UUID: String]) {
        // La sesión abierta dormida porque su rama no estaba activa: si ahora lo está, se lanza.
        let selected = selectedDormantSession()
        confirmedHeads.formUnion(heads.keys)
        var merged = mainHeads
        for (id, head) in heads where project(id) != nil { merged[id] = head }
        merged = merged.filter { project($0.key) != nil }
        if mainHeads != merged {
            let before = mainHeads
            mainHeads = merged
            scheduleSave()
            for (id, head) in merged { warnIfHeadMoved(projectId: id, from: before[id], to: head) }
        }
        if let selected, let ctx = sessionContext(selected), isActive(ctx.branch, in: ctx.project) {
            activate(selected)
        }
        // Las que abriste antes de saber la rama de su carpeta: si las seguís mirando, ahora sí se
        // lanzan (o quedan dormidas, si resultó que la carpeta está en otra rama).
        let waiting = awaitingHead
        awaitingHead = []
        for id in waiting where selection == .session(id) { activate(id) }
    }

    /// Algo (vos en una terminal, otra app) cambió la rama de la carpeta principal sin pasar por
    /// Hive. Si la rama de antes tenía sesiones corriendo, ahora están viendo otra: preguntamos.
    private func warnIfHeadMoved(projectId: UUID, from old: String?, to new: String) {
        guard let old, !old.isEmpty, !new.isEmpty, old != new, let project = project(projectId),
              let branch = project.branches.first(where: { $0.mode == .main && $0.name == old }) else { return }
        let running = branch.sessions.filter { runtimes[$0.id]?.isRunning == true }
        guard !running.isEmpty else { return }
        let branchId = branch.id
        let message = running.count == 1
            ? "La sesión «\(running[0].name)» quedó viendo «\(new)» en «\(project.name)». ¿La movés a esa rama en Havebee?"
            : "Las \(running.count) sesiones de esa rama quedaron viendo «\(new)» en «\(project.name)». ¿Las movés a esa rama en Havebee?"
        alert = AppAlert(title: "Algo cambió la carpeta principal de «\(old)» a «\(new)»",
                         message: message,
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

    /// Los repos como carpetas para mirar (ver `GitLayout`).
    func gitLayout() -> GitLayout {
        GitLayout(repositories: repoProjects.map { p in
            GitLayout.Repository(path: p.path, worktrees: p.branches.compactMap { $0.mode == .worktree ? $0.worktreePath : nil })
        })
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

/// Qué lee una revisión de git. Cada caso incluye lo del anterior.
enum GitRefreshScope: Int, Comparable {
    /// Lo que cambió en las carpetas con agentes trabajando, sin buscar ramas ni worktrees nuevos
    /// (con la app en segundo plano).
    case working
    /// Lo que cambió, en todas las carpetas.
    case changed
    /// Todo, haya cambiado o no.
    case all

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Lo que leyó una revisión de git.
private struct GitScan: Sendable {
    var branches: [UUID: RepositoryBranches] = [:]
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
        case head(UUID, String, RepositoryBranches?)
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
                    return .head(id, git.currentBranch(path) ?? "", worktrees
                                 ? RepositoryBranches(local: git.localBranches(path), remote: git.remoteBranches(path), worktrees: git.worktrees(path)) : nil)
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
                case .head(let id, let head, let branches):
                    scan.heads[id] = head
                    if let branches { scan.worktrees[id] = branches.worktrees; scan.branches[id] = branches }
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
