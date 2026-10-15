import AppKit
import HiveCore
import Observation

/// Estado de la app y coordinador de sus acciones. Las decisiones viven en HiveCore (funciones
/// puras); el store las aplica y maneja los efectos (git, procesos, archivos, avisos) a través
/// de `AppEnvironment`, que en los tests se reemplaza.
@Observable @MainActor
public final class AppStore {
    public static let shared = AppStore(environment: .live())

    public private(set) var projects: [Project] = []
    public private(set) var selection: SidebarItem?
    private(set) var expanded: Set<UUID> = []
    /// Estado de git por carpeta (carpeta principal de cada proyecto y cada worktree).
    private(set) var dirStatus: [String: GitStatus] = [:]
    /// Rama que tiene hoy la carpeta principal de cada proyecto ("" si HEAD está desacoplado).
    private(set) var mainHeads: [UUID: String] = [:]
    public private(set) var runtimes: [UUID: SessionRuntime] = [:]
    private(set) var lastSessionByProject: [UUID: UUID] = [:]
    /// Sube cada vez que se agrega algo al historial de una sesión (para refrescar el panel).
    private(set) var historyVersions: [UUID: Int] = [:]
    /// Sube cada vez que Hive escribe un .mcp.json (para refrescar la lista).
    private(set) var mcpVersion = 0
    /// Comandos del proyecto corriendo (en la esquina de la ventana).
    public private(set) var commandRuns: [CommandRun] = []

    // Diálogos y hojas abiertas.
    public var alert: AppAlert?
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
    @ObservationIgnored private var loginPATH: String?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var watcher: EventWatcher?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

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
        try? EventBridge.install(paths: environment.paths)
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
            MainActor.assumeIsolated { self?.refreshGit() }
        })
        refreshGit()
    }

    public var git: GitClient { environment.git }

    // MARK: - Consultas

    /// Los repos, sin el proyecto «Terminales».
    public var repoProjects: [Project] { projects.repos }
    public var scratchProject: Project? { projects.scratch }

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

    private func markSeen(_ rt: SessionRuntime) {
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

    private func isFocused(_ id: UUID) -> Bool {
        environment.isAppActive() && selection == .session(id)
    }

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
        let r = await Task.detached { git.checkout(name, in: path) }.value
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

    // MARK: - Sesiones

    /// Nueva sesión en una rama; si la rama está inactiva, primero pide el checkout.
    public func requestNewSession(branchId: UUID, kind: SessionKind) {
        guard let ctx = branchContext(branchId) else { return }
        if !isActive(ctx.branch, in: ctx.project) {
            requestCheckout(branchId: branchId, then: .createSession(kind))
            return
        }
        createSession(branchId: branchId, kind: kind)
    }

    private func createSession(branchId: UUID, kind: SessionKind) {
        guard let ctx = branchContext(branchId) else { return }
        let session = Session(name: ctx.branch.nextSessionName(for: kind), kind: kind, createdAt: environment.now())
        projects.updateBranch(branchId) { $0.sessions.append(session) }
        runtimes[session.id] = SessionRuntime(sessionId: session.id, kind: kind)
        expanded.formUnion([ctx.project.id, branchId])
        scheduleSave()
        select(.session(session.id))
    }

    /// Abre una sesión dormida de una rama inactiva: primero hace falta el checkout.
    public func openInactiveSession(_ id: UUID) {
        guard let ctx = sessionContext(id) else { return }
        requestCheckout(branchId: ctx.branch.id, then: .openSession(id))
    }

    /// Lanza el proceso de una sesión (agente o shell) en su terminal.
    func launch(_ id: UUID) {
        guard let ctx = sessionContext(id), let rt = runtimes[id], !rt.isRunning else { return }
        let dir = ctx.project.directory(for: ctx.branch)
        guard FileManager.default.fileExists(atPath: dir) else {
            alert = AppAlert(title: "La carpeta no existe", message: dir)
            return
        }
        let plan = LaunchPlanner.plan(launchContext(for: ctx.session, project: ctx.project, branch: ctx.branch, directory: dir))

        let terminal = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        TerminalTheme.apply(to: terminal)
        // El cursor toma el color del proyecto: así sabés en cuál estás de un vistazo.
        terminal.caretColor = ctx.project.tint.nsColor
        // En los agentes, /clear deja lo anterior en el scroll con una divisoria.
        terminal.preservesScrollbackOnClear = ctx.session.kind.isAgent
        let bridge = TerminalBridge(sessionId: id, store: self)
        terminal.processDelegate = bridge
        let clock = rt.activity
        terminal.setProcessOutputHandler { clock.touch() }
        terminal.onUserInput = { [weak self] data in self?.userInput(id, data) }

        var started = true
        if let binary = plan.binary {
            if let executable = environment.processes.resolve(binary, path: currentPATH) {
                environment.processes.start(terminal, executable: executable, args: plan.args, environment: plan.environmentList, directory: dir)
            } else {
                let kind = ctx.session.kind
                terminal.feed(text: "\r\n  No encontré `\(binary)` en tu PATH.\r\n\r\n  Para instalar \(kind.label):\r\n    \(kind.installHint)\r\n\r\n  Después tocá «Reanudar».\r\n")
                started = false
            }
        } else {
            environment.processes.start(terminal, executable: environment.loginShell, args: plan.args, environment: plan.environmentList, directory: dir)
        }

        let now = environment.now()
        projects.updateSession(id) { session in
            session.agentSessionId = plan.agentSessionId ?? session.agentSessionId
            session.lastLaunchedAt = now
        }
        scheduleSave()
        rt.terminal = terminal
        rt.bridge = bridge
        rt.hooksSeen = false
        rt.workingSince = nil
        rt.status = started ? .idle : .exited(nil)
    }

    /// Junta todo lo que el planificador necesita (con las búsquedas en disco ya hechas).
    func launchContext(for session: Session, project: Project, branch: Branch, directory: String) -> LaunchContext {
        let settings = environment.settings()
        let agents = environment.agents
        if session.kind.reportsConversation {
            history.ensureMarkdown(session: session, place: project.isScratch ? project.name : "\(project.name) › \(branch.name)")
        }
        let mcpFile = MCPConfig.effectiveFile(directory: directory, projectPath: project.path)
        let mcpServers = mcpFile.map(MCPConfig.load) ?? []
        var discovered: String?
        if let since = session.lastLaunchedAt {
            let claimed = projects.claimedAgentIds(session.kind, except: session.id)
            switch session.kind {
            case .codex where session.agentSessionId == nil:
                discovered = agents.discoverCodexThread(cwd: directory, since: since, excluding: claimed, now: environment.now())
            case .gemini:
                discovered = agents.discoverGeminiSession(cwd: directory, since: since, excluding: claimed)
            default:
                break
            }
        }
        let geminiSettings = session.kind == .gemini
            ? MCPConfig.writeGeminiSettings(mcpServers, to: environment.paths.geminiDir.appendingPathComponent("\(session.id.uuidString).json"))
            : nil
        return LaunchContext(
            session: session, project: project, branch: branch, directory: directory, path: currentPATH,
            inheritedEnvironment: environment.inheritedEnvironment, paths: environment.paths,
            claudeInline: settings.claudeInline, historyHint: settings.historyHint,
            claudeConversationExists: session.kind == .claude && session.agentSessionId.map(agents.claudeConversationExists) == true,
            discoveredAgentId: discovered, mcpFile: mcpFile, mcpServers: mcpServers, geminiSettingsPath: geminiSettings,
            codexExistingNotify: session.kind == .codex ? agents.codexExistingNotify() : nil)
    }

    private var currentPATH: String {
        loginPATH ?? LoginShell.fallbackPATH(home: environment.home.path, inherited: environment.inheritedEnvironment["PATH"])
    }

    public func relaunch(_ id: UUID) {
        guard let rt = runtimes[id] else { return }
        if rt.isRunning { rt.terminal?.terminate() }
        rt.terminal?.removeFromSuperview()
        rt.terminal = nil
        rt.status = .dormant
        launch(id)
    }

    public func stop(_ id: UUID) {
        runtimes[id]?.terminal?.terminate()
    }

    func processExited(_ id: UUID, terminal: HiveTerminalView, code: Int32?) {
        // Ignoramos avisos de una terminal vieja que ya reemplazamos al reiniciar.
        guard let rt = runtimes[id], rt.terminal === terminal else { return }
        rt.status = .exited(code)
        rt.unseen = false
        updateBadge()
    }

    // MARK: - Estado de los agentes

    func userInput(_ id: UUID, _ data: ArraySlice<UInt8>) {
        guard let rt = runtimes[id] else { return }
        if rt.unseen { markSeen(rt) }
        // Enter en un agente: mandaste un prompt o aprobaste algo, así que empieza a trabajar.
        guard rt.kind.isAgent, data.contains(13), rt.status != .working else { return }
        setStatus(rt, .working)
    }

    /// Aplica los eventos de los agentes (los decide `AgentEventInterpreter`).
    func handle(_ events: [HiveEvent]) {
        for event in events {
            guard let rt = runtimes[event.sessionId], rt.isRunning, let ctx = sessionContext(event.sessionId) else { continue }
            rt.hooksSeen = true
            let outcome = AgentEventInterpreter.interpret(event, status: rt.status, agentSessionId: ctx.session.agentSessionId)
            if !outcome.history.isEmpty {
                let place = ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)"
                history.ensureMarkdown(session: ctx.session, place: place)
                for entry in outcome.history {
                    history.append(HistoryEntry(date: environment.now(), role: entry.role, text: entry.text),
                                   sessionId: ctx.session.id, agentName: ctx.session.kind.label)
                }
                historyVersions[ctx.session.id, default: 0] += 1
            }
            if outcome.agentSessionId != nil || outcome.reply != nil || outcome.touchesActivity {
                let now = environment.now()
                projects.updateSession(event.sessionId) { session in
                    if let id = outcome.agentSessionId { session.agentSessionId = id }
                    if let reply = outcome.reply { session.lastMessage = reply }
                    if outcome.touchesActivity { session.lastActivityAt = now }
                }
                scheduleSave()
            }
            if let status = outcome.status { setStatus(rt, status, notify: outcome.notification) }
        }
    }

    private func setStatus(_ rt: SessionRuntime, _ status: SessionStatus, notify body: String? = nil) {
        guard rt.status != status else { return }
        rt.status = status
        if status == .working {
            rt.workingSince = environment.now()
        } else if status.needsYou {
            if !isFocused(rt.sessionId) {
                rt.unseen = true
                if let body { postNotification(rt.sessionId, body: body, attention: status == .attention) }
            }
            updateBadge()
        }
    }

    /// Cada segundo, la regla del silencio para los agentes que figuran trabajando.
    func tick() {
        let now = environment.now()
        for rt in runtimes.values where rt.kind.isAgent && rt.status == .working {
            let verdict = SilenceRule.evaluate(now: now, workingSince: rt.workingSince, lastOutput: rt.activity.last, hooksSeen: rt.hooksSeen)
            if verdict.stopWorking { setStatus(rt, .waiting, notify: verdict.notify ? "Espera tu respuesta." : nil) }
        }
    }

    private func postNotification(_ id: UUID, body: String, attention: Bool) {
        guard let ctx = sessionContext(id) else { return }
        environment.notifier.post(sessionId: id,
                                  title: ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)",
                                  subtitle: "\(ctx.session.name) · \(attention ? "Necesita permiso" : "Tu turno")",
                                  body: body)
    }

    private func updateBadge() {
        let count = runtimes.values.filter(\.unseen).count
        environment.setDockBadge(count > 0 ? "\(count)" : nil)
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

    private func refreshCarets(_ projectId: UUID) {
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

    // MARK: - Archivar

    public func requestArchive(_ id: UUID) {
        guard let rt = runtimes[id] else { return }
        if rt.status == .working {
            alert = AppAlert(title: "La sesión está trabajando",
                             message: "Si la archivás se corta lo que está haciendo. La conversación queda guardada y la podés restaurar.",
                             actionTitle: "Archivar igual",
                             action: { [weak self] in self?.archive(id) })
        } else {
            archive(id)
        }
    }

    public func archive(_ id: UUID) {
        guard let ctx = sessionContext(id) else { return }
        if let rt = runtimes[id] {
            rt.terminal?.terminate()
            rt.terminal?.removeFromSuperview()
            rt.terminal = nil
            rt.status = .dormant
            rt.unseen = false
        }
        environment.notifier.clear(id)
        updateBadge()
        let neighbor = ctx.project.neighborSession(of: id)
        let now = environment.now()
        projects.updateSession(id) { $0.archivedAt = now }
        scheduleSave()
        if selection == .session(id) {
            select(neighbor.map { .session($0) } ?? .branch(ctx.branch.id))
        }
    }

    public func unarchive(_ id: UUID) {
        projects.updateSession(id) { $0.archivedAt = nil }
        if let ctx = sessionContext(id) { expanded.formUnion([ctx.project.id, ctx.branch.id]) }
        scheduleSave()
        select(.session(id))
    }

    // MARK: - Comandos del proyecto

    public func saveCommand(projectId: UUID, commandId: UUID?, name: String, command: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        projects.updateProject(projectId) { p in
            if let commandId, let i = p.commands.firstIndex(where: { $0.id == commandId }) {
                p.commands[i].name = name.isEmpty ? command : name
                p.commands[i].command = command
            } else {
                p.commands.append(ProjectCommand(name: name.isEmpty ? command : name, command: command))
            }
        }
        scheduleSave()
    }

    public func deleteCommand(projectId: UUID, commandId: UUID) {
        projects.updateProject(projectId) { $0.commands.removeAll { $0.id == commandId } }
        scheduleSave()
    }

    /// Rama donde corre un comando si no se elige otra: la que está abierta, o la activa de la carpeta principal.
    public func defaultBranch(for project: Project) -> Branch? {
        switch selection {
        case .session(let id)?:
            if let ctx = sessionContext(id), ctx.project.id == project.id { return ctx.branch }
        case .branch(let id)?:
            if let ctx = branchContext(id), ctx.project.id == project.id { return ctx.branch }
        default:
            break
        }
        return project.mainBranch(head: mainHeads[project.id])
    }

    public func runningRun(commandId: UUID, branchId: UUID) -> CommandRun? {
        commandRuns.first { $0.commandId == commandId && $0.branchId == branchId && $0.running }
    }

    public func run(_ commandId: UUID, projectId: UUID, branchId: UUID? = nil) {
        guard let project = project(projectId),
              let command = project.commands.first(where: { $0.id == commandId }),
              let branch = branchId.flatMap({ id in project.branches.first { $0.id == id } }) ?? defaultBranch(for: project) else { return }
        if let existing = runningRun(commandId: commandId, branchId: branch.id) {
            showRun(existing.id)
            return
        }
        let dir = project.directory(for: branch)
        guard FileManager.default.fileExists(atPath: dir) else {
            alert = AppAlert(title: "La carpeta no existe", message: dir)
            return
        }
        let run = CommandRun(projectId: project.id, branchId: branch.id, branchName: branch.name, commandId: command.id,
                             name: command.name, command: command.command, directory: dir)
        start(run)
        commandRuns.append(run)
        showRun(run.id)
    }

    private func start(_ run: CommandRun) {
        let terminal = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), scrollback: 5_000)
        TerminalTheme.apply(to: terminal)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bridge = CommandBridge(runId: run.id, store: self)
        terminal.processDelegate = bridge
        let env = SessionEnvironment.base(inherited: environment.inheritedEnvironment, directory: run.directory, path: currentPATH)
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        // Shell interactivo de login: así carga nvm, aliases y lo que tengas en tu .zshrc.
        environment.processes.start(terminal, executable: environment.loginShell, args: ["-l", "-i", "-c", run.command],
                                    environment: env, directory: run.directory)
        run.terminal = terminal
        run.bridge = bridge
        run.running = true
        run.exitCode = nil
        run.startedAt = environment.now()
    }

    public func showRun(_ id: UUID) {
        dockRunId = id
        dockExpanded = true
    }

    public func stopRun(_ id: UUID) {
        guard let run = commandRuns.first(where: { $0.id == id }), run.running, let terminal = run.terminal else { return }
        // Como apretar Ctrl+C; si no termina en unos segundos, lo cortamos.
        terminal.sendInput([3])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak run] in
            guard let run, run.running else { return }
            run.terminal?.terminate()
        }
    }

    public func restartRun(_ id: UUID) {
        guard let run = commandRuns.first(where: { $0.id == id }) else { return }
        if run.running { run.terminal?.terminate() }
        run.terminal?.removeFromSuperview()
        start(run)
    }

    public func closeRun(_ id: UUID) {
        guard let index = commandRuns.firstIndex(where: { $0.id == id }) else { return }
        let run = commandRuns[index]
        if run.running { run.terminal?.terminate() }
        run.terminal?.removeFromSuperview()
        commandRuns.remove(at: index)
        if dockRunId == id { dockRunId = commandRuns.last?.id }
        if commandRuns.isEmpty { dockExpanded = false }
    }

    func commandExited(_ runId: UUID, terminal: HiveTerminalView, code: Int32?) {
        // Ignoramos avisos de una terminal vieja que ya reemplazamos al reiniciar.
        guard let run = commandRuns.first(where: { $0.id == runId }), run.terminal === terminal else { return }
        run.running = false
        run.exitCode = code
    }

    public func commandSuggestions(for project: Project) -> [CommandSuggestions.Suggestion] {
        CommandSuggestions.detect(projectPath: project.path, existing: project.commands)
    }

    // MARK: - MCP

    public func saveMCP(_ server: MCPServer, replacing oldName: String?, projectId: UUID) {
        guard let project = project(projectId) else { return }
        do {
            try MCPConfig.upsert(server, replacing: oldName, dir: project.path)
            mcpVersion += 1
        } catch {
            alert = AppAlert(title: "No se pudo guardar .mcp.json", message: error.localizedDescription)
        }
    }

    public func removeMCP(_ name: String, projectId: UUID) {
        guard let project = project(projectId) else { return }
        do {
            try MCPConfig.remove(name, dir: project.path)
            mcpVersion += 1
        } catch {
            alert = AppAlert(title: "No se pudo guardar .mcp.json", message: error.localizedDescription)
        }
    }

    // MARK: - Diff

    public func openDiff(directory: String, status: GitStatus, change: GitChange, staged: Bool) {
        diffTarget = DiffTarget.make(directory: directory, status: status, change: change, staged: staged)
    }

    // MARK: - Renombrar y quitar

    public func beginRename(_ item: SidebarItem) {
        switch item {
        case .project(let id): renameText = project(id)?.name ?? ""
        case .session(let id): renameText = sessionContext(id)?.session.name ?? ""
        case .branch: return
        }
        rename = RenameRequest(item: item)
    }

    public func commitRename(_ request: RenameRequest) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch request.item {
        case .project(let id): projects.updateProject(id) { $0.name = name }
        case .session(let id): projects.updateSession(id) { $0.name = name }
        case .branch: return
        }
        scheduleSave()
    }

    public func requestRemoval(_ item: SidebarItem) {
        switch item {
        case .project(let id):
            guard let p = project(id), !p.isScratch else { return }
            pendingRemoval = PendingRemoval(item: item, title: "¿Quitar «\(p.name)» de Hive?",
                                            message: "Se cierran sus sesiones. No se borra nada del disco.", isWorktree: false)
        case .branch(let id):
            guard let ctx = branchContext(id) else { return }
            let worktree = ctx.branch.mode == .worktree
            let message = worktree
                ? "Se cierran sus sesiones. La rama de git no se borra. Podés conservar el worktree en \(ctx.branch.worktreePath ?? "") o borrarlo."
                : "Se cierran sus sesiones. La rama de git no se borra."
            pendingRemoval = PendingRemoval(item: item, title: "¿Quitar la rama «\(ctx.branch.name)»?", message: message, isWorktree: worktree)
        case .session(let id):
            guard let ctx = sessionContext(id) else { return }
            pendingRemoval = PendingRemoval(item: item, title: "¿Eliminar «\(ctx.session.name)»?",
                                            message: "Se cierra la terminal. La conversación del agente queda guardada en su historial.", isWorktree: false)
        }
    }

    public func remove(_ item: SidebarItem, deleteWorktree: Bool = false, force: Bool = false) {
        Task { await performRemove(item, deleteWorktree: deleteWorktree, force: force) }
    }

    /// Quita un elemento. Si hay que borrar un worktree y falla, ofrece forzarlo. Devuelve si se quitó.
    @discardableResult
    func performRemove(_ item: SidebarItem, deleteWorktree: Bool = false, force: Bool = false) async -> Bool {
        switch item {
        case .session(let id):
            guard let ctx = sessionContext(id) else { return false }
            terminate([id])
            history.delete(id)
            projects.updateBranch(ctx.branch.id) { $0.sessions.removeAll { $0.id == id } }
            scheduleSave()
            if selection == item { select(.branch(ctx.branch.id)) }
            return true
        case .branch(let id):
            guard let ctx = branchContext(id) else { return false }
            if deleteWorktree, let path = ctx.branch.worktreePath {
                let repo = ctx.project.path
                let git = self.git
                let r = await Task.detached { git.removeWorktree(path, force: force, in: repo) }.value
                guard r.ok else {
                    alert = AppAlert(title: "No se pudo borrar el worktree",
                                     message: "\(r.errorMessage)\n\n¿Borrarlo igual? Se pierden los cambios sin commitear.",
                                     actionTitle: "Borrar igual",
                                     action: { [weak self] in self?.remove(item, deleteWorktree: true, force: true) })
                    return false
                }
            } else if let path = ctx.branch.worktreePath, ctx.branch.mode == .worktree {
                // El worktree queda en disco: que la detección automática no lo vuelva a sumar.
                projects.updateProject(ctx.project.id) { $0.ignoredWorktrees.append(path) }
            }
            dropBranch(id)
            return true
        case .project(let id):
            guard let p = project(id), !p.isScratch else { return false }
            terminate(p.allSessions.map(\.id))
            let selectionWasInside = projects.contains(selection, inProject: id)
            projects.removeAll { $0.id == id }
            if selectionWasInside { select(nil) }
            scheduleSave()
            return true
        }
    }

    private func dropBranch(_ id: UUID) {
        guard let ctx = branchContext(id) else { return }
        terminate(ctx.branch.sessions.map(\.id))
        let selectionWasInside = selection == .branch(id) || ctx.branch.sessions.contains(where: { selection == .session($0.id) })
        projects.updateProject(ctx.project.id) { $0.branches.removeAll { $0.id == id } }
        scheduleSave()
        if selectionWasInside { select(.project(ctx.project.id)) }
        refreshGit()
    }

    private func terminate(_ ids: [UUID]) {
        for id in ids {
            runtimes[id]?.terminal?.terminate()
            runtimes[id]?.terminal?.removeFromSuperview()
            runtimes[id] = nil
            environment.notifier.clear(id)
        }
        updateBadge()
    }

    // MARK: - Git

    /// Pide una revisión de git en segundo plano (una a la vez).
    public func refreshGit() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refreshGitNow()
            self?.refreshTask = nil
        }
    }

    /// Revisa git (estado de cada carpeta, rama de la carpeta principal y worktrees nuevos) y espera.
    func refreshGitNow() async {
        var dirs = Set<String>()
        for p in repoProjects {
            dirs.insert(p.path)
            for b in p.branches where b.mode == .worktree { if let path = b.worktreePath { dirs.insert(path) } }
        }
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
        if dirStatus != statuses { dirStatus = statuses }
        if mainHeads != current { mainHeads = current }
        var found = false
        for (id, worktrees) in trees where syncWorktrees(id, worktrees) { found = true }
        // Hay ramas nuevas: traemos su estado de git en esta misma pasada.
        if found { await refreshGitNow() }
    }

    // MARK: - Persistencia

    private func load() {
        switch stateStore.load(now: environment.now()) {
        case .loaded(let state):
            projects = state.projects
            selection = state.selection
            lastSessionByProject = state.lastSessions ?? [:]
            expanded = Set(state.expanded)
        case .empty, .corrupted:
            break
        }
        for i in projects.indices {
            var project = projects[i]
            AppearanceDefaults.apply(to: &project, others: projects, logos: environment.logos)
            projects[i] = project
        }
        projects.ensureScratch(home: environment.home.path)
        for p in projects {
            if !p.isScratch { mainHeads[p.id] = git.currentBranch(p.path) ?? "" }
            for s in p.allSessions { runtimes[s.id] = SessionRuntime(sessionId: s.id, kind: s.kind) }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        guard environment.saveDelay > 0 else {
            saveNow()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + environment.saveDelay, execute: work)
    }

    public func saveNow() {
        saveWork?.cancel()
        let state = HiveState(projects: projects, selection: selection, expanded: Array(expanded), lastSessions: lastSessionByProject)
        try? stateStore.save(state)
    }

    public func shutdown() {
        saveNow()
        for rt in runtimes.values { rt.terminal?.terminate() }
        for run in commandRuns where run.running { run.terminal?.terminate() }
        watcher?.stop()
        timers.forEach { $0.invalidate() }
    }
}
