import AppKit
import HiveCore
import Observation

/// Estado de la app y coordinador de sus acciones. Las decisiones viven en HiveCore (funciones
/// puras); el store las aplica y maneja los efectos (git, procesos, archivos, avisos) a través
/// de `AppEnvironment`, que en los tests se reemplaza.
@Observable @MainActor
public final class AppStore {
    public static let shared = AppStore(environment: .live())

    public internal(set) var projects: [Project] = []
    public internal(set) var selection: SidebarItem?
    var expanded: Set<UUID> = []
    /// Estado de git por carpeta (carpeta principal de cada proyecto y cada worktree).
    var dirStatus: [String: GitStatus] = [:]
    /// Rama que tiene hoy la carpeta principal de cada proyecto ("" si HEAD está desacoplado).
    var mainHeads: [UUID: String] = [:]
    /// Carpetas de worktrees que ya no existen (se borraron o movieron por fuera de Hive).
    public internal(set) var missingWorktrees: Set<String> = []
    public internal(set) var runtimes: [UUID: SessionRuntime] = [:]
    var lastSessionByProject: [UUID: UUID] = [:]
    /// Sube cada vez que se agrega algo al historial de una sesión (para refrescar el panel).
    var historyVersions: [UUID: Int] = [:]
    /// Sube cada vez que Hive escribe un .mcp.json (para refrescar la lista).
    var mcpVersion = 0
    /// Comandos del proyecto corriendo (en la esquina de la ventana).
    public internal(set) var commandRuns: [CommandRun] = []

    // Diálogos y hojas abiertas.
    /// Alertas en cola: se muestran de a una y en orden.
    public internal(set) var alerts: [AppAlert] = []
    /// La alerta visible. Asignar una la encola (no pisa la que se está mostrando); asignar nil
    /// cierra la visible y deja ver la siguiente.
    public var alert: AppAlert? {
        get { alerts.first }
        set {
            if let newValue {
                // La misma alerta dos veces seguidas (ej. un error que se repite) se muestra una sola vez.
                guard !alerts.contains(where: { $0.title == newValue.title && $0.message == newValue.message }) else { return }
                alerts.append(newValue)
            } else if !alerts.isEmpty {
                alerts.removeFirst()
            }
        }
    }
    public var pendingCheckout: PendingCheckout?
    public var pendingRemoval: PendingRemoval?
    public var rename: RenameRequest?
    public var renameText = ""
    public var newBranchTarget: NewBranchTarget?
    public var customizeTarget: CustomizeTarget?
    public var commandEditor: CommandEditorTarget?
    public var mcpEditor: MCPEditorTarget?
    public var diffTarget: DiffTarget?
    public var showSwitcher = false
    public var dockExpanded = false
    public var dockRunId: UUID?

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let stateStore: StateStore
    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored var loginPATH: String?
    @ObservationIgnored var saveWork: DispatchWorkItem?
    @ObservationIgnored var watcher: EventWatcher?
    @ObservationIgnored var timers: [Timer] = []
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    /// Llegó un pedido de revisión mientras otra corría: al terminar se hace otra pasada.
    @ObservationIgnored var refreshPending = false
    /// Sube con cada cambio de git que hace Hive (checkout, proyecto o rama nuevos, rama quitada).
    /// Una revisión que empezó antes descarta las ramas actuales que leyó, porque pueden ser viejas.
    @ObservationIgnored var gitGeneration = 0
    /// Última revisión de git hecha con la app en segundo plano.
    @ObservationIgnored var lastBackgroundRefresh = Date.distantPast
    /// Sesiones y comandos a los que ya avisamos que su carpeta no existe (para no repetirlo).
    @ObservationIgnored var warnedMissing: Set<UUID> = []
    /// Sesiones que se están reiniciando (esperando a que termine el proceso viejo).
    @ObservationIgnored var relaunching: Set<UUID> = []
    /// Quienes esperan que termine el proceso de una terminal (ver `waitForExit`).
    /// El estado guardado existe pero no se pudo leer: no se guarda nada para no pisarlo.
    @ObservationIgnored var persistenceBlocked = false
    /// El último guardado falló (y ya se avisó).
    @ObservationIgnored var saveFailed = false
    @ObservationIgnored var exitWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    /// Carga el estado guardado. No arranca nada: eso lo hace `start()`.
    public init(environment: AppEnvironment) {
        self.environment = environment
        stateStore = StateStore(file: environment.paths.stateFile)
        history = HistoryStore(directory: environment.paths.historyDir)
        loginPATH = environment.cachedLoginPATH
        load()
    }

    /// Arranca lo que corre en segundo plano: eventos de los agentes, avisos, revisión de git.
    public func start() {
        do {
            try EventBridge.install(paths: environment.paths)
        } catch {
            alert = AppAlert(title: "No pude instalar el puente de eventos de los agentes",
                             message: "No vas a ver sus estados (trabajando, tu turno, necesita permiso).\n\n\(error.localizedDescription)")
        }
        let resolve = environment.resolveLoginPATH
        Task { [weak self] in
            guard let path = await Task.detached(priority: .utility, operation: { resolve() }).value else { return }
            self?.loginPATH = path
            self?.environment.storeLoginPATH(path)
        }
        watcher = EventWatcher(directory: environment.paths.eventsDir) { [weak self] events in
            Task { @MainActor in self?.handle(events) }
        }
        watcher?.start()
        environment.notifier.onOpen = { [weak self] id in self?.openFromNotification(id) }
        environment.notifier.setup()
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicGitRefresh() }
        })
        // También corrige la rama de cada carpeta principal, que se cargó del estado guardado.
        refreshGit()
    }

    public var git: GitClient { environment.git }

    // MARK: - Consultas

    /// Los repos, sin el proyecto «Terminales».
    public var repoProjects: [Project] { projects.repos }
    public var scratchProject: Project? { projects.scratch }

    /// Cierra una alerta puntual (la que se estaba mostrando), aunque ya haya otras en la cola.
    public func dismissAlert(_ id: UUID) {
        alerts.removeAll { $0.id == id }
    }

    public func project(_ id: UUID) -> Project? { projects.project(id) }
    public func branchContext(_ id: UUID) -> (project: Project, branch: Branch)? { projects.branchContext(id) }
    public func sessionContext(_ id: UUID) -> (project: Project, branch: Branch, session: Session)? { projects.sessionContext(id) }

    public func isActive(_ branch: Branch, in project: Project) -> Bool {
        project.isActive(branch, head: mainHeads[project.id])
    }

    public func gitStatus(for branch: Branch, in project: Project) -> GitStatus? {
        isActive(branch, in: project) ? dirStatus[project.directory(for: branch)] : nil
    }

    public func mainHead(of projectId: UUID) -> String { mainHeads[projectId] ?? "" }

    /// El worktree de la rama ya no está en disco.
    public func isMissing(_ branch: Branch) -> Bool {
        guard branch.mode == .worktree, let path = branch.worktreePath else { return false }
        return missingWorktrees.contains(path)
    }

    /// Revisa que exista la carpeta donde se va a lanzar algo. Si no está, avisa una sola vez por
    /// sesión o comando (`warnKey`), no cada vez que se vuelve a mirar.
    func folderExists(_ dir: String, branch: Branch, warnKey: UUID) -> Bool {
        guard !FileManager.default.fileExists(atPath: dir) else {
            warnedMissing.remove(warnKey)
            return true
        }
        if branch.mode == .worktree { missingWorktrees.insert(dir) }
        if warnedMissing.insert(warnKey).inserted {
            alert = AppAlert(title: "No encuentro la carpeta de «\(branch.name)»",
                             message: "\(dir)\n\nSe borró o se movió por fuera de Hive. Si ya no la usás, quitá la rama de Hive.")
        }
        return false
    }

    public var workingCount: Int { runtimes.values.filter { $0.status == .working }.count }
    public var runningCommandsCount: Int { commandRuns.filter(\.running).count }
    public var currentProjectId: UUID? { projects.projectId(of: selection) }

    public func activity(of sessions: [Session]) -> Activity {
        var activity = Activity()
        for session in sessions {
            guard let rt = runtimes[session.id] else { continue }
            if rt.status == .attention { activity.attention += 1 }
            else if rt.unseen { activity.pending += 1 }
            else if rt.status == .working { activity.working += 1 }
        }
        return activity
    }

    public func activity(of project: Project) -> Activity { activity(of: project.activeSessions) }

    public func logos(in path: String) -> [String] { environment.logos(path) }

    public func mcpSuggestions(for project: Project, existing: [MCPServer]) -> [MCPCatalog.Item] {
        MCPCatalog.suggestions(projectPath: project.path, home: environment.home, existing: existing)
    }

    public func mcpGlobals(for project: Project) -> [MCPConfig.GlobalGroup] {
        MCPConfig.globals(projectPath: project.path, home: environment.home, codexHome: environment.agents.codexHome)
    }

    // MARK: - Selección y sidebar

    public func select(_ item: SidebarItem?) {
        guard item != selection else { return }
        selection = item
        if case .session(let id)? = item, let ctx = sessionContext(id) {
            lastSessionByProject[ctx.project.id] = id
        }
        scheduleSave()
    }

    /// Abre un proyecto en su última sesión activa (o en la más reciente, o en su resumen).
    public func openProject(_ id: UUID) {
        guard let project = project(id) else { return }
        if let session = project.sessionToOpen(last: lastSessionByProject[id]) {
            select(.session(session))
        } else {
            select(.project(id))
        }
    }

    public func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }

    public func setExpanded(_ id: UUID, _ value: Bool) {
        if value { expanded.insert(id) } else { expanded.remove(id) }
        scheduleSave()
    }

    /// Se llama cuando una sesión aparece en pantalla: la marca como vista y la lanza si dormía.
    public func activate(_ id: UUID) {
        guard let ctx = sessionContext(id), let rt = runtimes[id] else { return }
        markSeen(rt)
        if rt.status == .dormant && isActive(ctx.branch, in: ctx.project) {
            launch(id)
        }
    }

    public func appBecameActive() {
        if case .session(let id)? = selection, let rt = runtimes[id] { markSeen(rt) }
        refreshGit()
    }

    func markSeen(_ rt: SessionRuntime) {
        if rt.unseen { rt.unseen = false }
        environment.notifier.clear(rt.sessionId)
        updateBadge()
    }

    func openFromNotification(_ id: UUID) {
        guard let ctx = sessionContext(id) else { return }
        NSApp?.activate(ignoringOtherApps: true)
        expanded.formUnion([ctx.project.id, ctx.branch.id])
        select(.session(id))
        activate(id)
    }

    func isFocused(_ id: UUID) -> Bool {
        environment.isAppActive() && selection == .session(id)
    }

    // MARK: - Apariencia y orden

    public func updateAppearance(projectId: UUID, name: String, color: TintColor, icon: ProjectIcon) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        projects.updateProject(projectId) { p in
            if !trimmed.isEmpty { p.name = trimmed }
            p.color = color
            p.icon = icon
        }
        scheduleSave()
        refreshCarets(projectId)
    }

    public func setColor(_ color: TintColor, project projectId: UUID) {
        projects.updateProject(projectId) { $0.color = color }
        scheduleSave()
        refreshCarets(projectId)
    }

    public func setColor(_ color: TintColor?, branch branchId: UUID) {
        projects.updateBranch(branchId) { $0.color = color }
        scheduleSave()
    }

    func refreshCarets(_ projectId: UUID) {
        guard let p = project(projectId) else { return }
        for s in p.allSessions { runtimes[s.id]?.terminal?.caretColor = p.tint.nsColor }
    }

    /// Copia una imagen elegida a la carpeta de Hive para que no dependa de dónde estaba.
    public func importIcon(from url: URL) -> String? {
        let dir = environment.paths.iconsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let destination = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination.path
        } catch {
            alert = AppAlert(title: "No se pudo usar la imagen", message: error.localizedDescription)
            return nil
        }
    }

    public func moveProjects(from source: IndexSet, to destination: Int) {
        projects.moveRepos(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    public func moveBranches(in projectId: UUID, from source: IndexSet, to destination: Int) {
        projects.updateProject(projectId) { $0.branches.moveItems(fromOffsets: source, toOffset: destination) }
        scheduleSave()
    }

    /// Los índices son de las sesiones visibles (sin las archivadas), como las muestra el sidebar.
    public func moveSessions(in branchId: UUID, from source: IndexSet, to destination: Int) {
        projects.updateBranch(branchId) { $0.moveActiveSessions(fromOffsets: source, toOffset: destination) }
        scheduleSave()
    }

    public func position(of item: SidebarItem) -> (index: Int, count: Int)? { projects.position(of: item) }

    /// Sube (-1) o baja (+1) un elemento un lugar.
    public func move(_ item: SidebarItem, by delta: Int) {
        if projects.move(item, by: delta) { scheduleSave() }
    }
}
