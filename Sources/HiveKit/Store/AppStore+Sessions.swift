import AppKit
import HiveCore

/// Sesiones: crear, lanzar, reiniciar, archivar.
extension AppStore {
    // MARK: - Sesiones

    /// Nueva sesión en una rama; si la rama está inactiva, primero pide el checkout.
    public func requestNewSession(branchId: UUID, kind: SessionKind) {
        guard let ctx = branchContext(branchId), !removingBranches.contains(branchId) else { return }
        if ctx.branch.setupCommand != nil {
            if let runId = preparationRuns[branchId] { showRun(runId) }
            showNotice("La sesión estará disponible cuando termine la preparación")
            return
        }
        if !isActive(ctx.branch, in: ctx.project) {
            requestCheckout(branchId: branchId, then: .createSession(kind))
            return
        }
        createSession(branchId: branchId, kind: kind)
    }

    func createSession(branchId: UUID, kind: SessionKind) {
        guard let ctx = branchContext(branchId), ctx.branch.setupCommand == nil, !removingBranches.contains(branchId) else { return }
        let session = Session(name: ctx.branch.nextSessionName(for: kind), kind: kind, createdAt: environment.now())
        projects.updateBranch(branchId) { $0.sessions.append(session) }
        runtimes[session.id] = SessionRuntime(sessionId: session.id, kind: kind)
        expanded.formUnion([ctx.project.id, branchId])
        scheduleSave()
        select(.session(session.id))
        requestTerminalFocus(session.id)
    }

    /// Abre una sesión dormida de una rama inactiva: primero hace falta el checkout.
    public func openInactiveSession(_ id: UUID) {
        guard let ctx = sessionContext(id) else { return }
        requestCheckout(branchId: ctx.branch.id, then: .openSession(id))
    }

    /// Lanza el proceso de una sesión (agente o shell) en su terminal. Las búsquedas en disco
    /// (historial, MCP, conversaciones anteriores) corren fuera del hilo principal; la terminal se
    /// crea al volver, si la sesión sigue ahí y nadie la lanzó mientras tanto.
    func launch(_ id: UUID) {
        guard !isShuttingDown, let ctx = sessionContext(id), !ctx.session.isArchived, let rt = runtimes[id], !rt.isRunning, !rt.isLaunching, !rt.isSwitchingAgent,
              !removingBranches.contains(ctx.branch.id), ctx.branch.setupCommand == nil else { return }
        let dir = ctx.project.directory(for: ctx.branch)
        guard folderExists(dir, project: ctx.project, branch: ctx.branch, warnKey: id) else { return }
        let builder = launchContextBuilder(for: ctx.session, project: ctx.project, branch: ctx.branch, directory: dir)
        guard environment.launchesInBackground else {
            startSession(id, plan: LaunchPlanner.plan(builder.build()), directory: dir)
            return
        }
        rt.isLaunching = true
        Task { [weak self] in
            let context = await Task.detached(priority: .userInitiated) { builder.build() }.value
            // Se canceló mientras se armaba (se cortaron sus sesiones para borrar la carpeta).
            guard rt.isLaunching else { return }
            rt.isLaunching = false
            // Mientras tanto se pudo borrar, archivar o lanzar por otro lado.
            guard let self, self.runtimes[id] === rt, !rt.isRunning,
                  let current = self.sessionContext(id), !current.session.isArchived else { return }
            self.startSession(id, plan: LaunchPlanner.plan(context), directory: dir)
        }
    }

    /// Junta lo que hace falta para armar el contexto de lanzamiento (sin tocar el disco todavía).
    func launchContextBuilder(for session: Session, project: Project, branch: Branch, directory: String) -> LaunchContextBuilder {
        let settings = environment.settings()
        return LaunchContextBuilder(
            session: session, project: project, branch: branch, directory: directory, path: currentPATH,
            inheritedEnvironment: environment.inheritedEnvironment, paths: environment.paths, agents: environment.agents,
            claudeInline: settings.claudeInline, historyHint: settings.historyHint, claudeUsage: settings.showClaudeUsage,
            claimedAgentIds: projects.claimedAgentIds(session.kind, except: session.id), now: environment.now())
    }

    /// Crea la terminal y arranca el proceso según el plan.
    private func startSession(_ id: UUID, plan: LaunchPlan, directory dir: String) {
        guard !isShuttingDown, let ctx = sessionContext(id), let rt = runtimes[id], ctx.branch.setupCommand == nil,
              !removingBranches.contains(ctx.branch.id) else { return }
        if plan.continuesInterruptedWork {
            // También cubre ⌘R antes de la primera revisión de git y un checkout mientras se
            // armaba el plan: nunca mandar a trabajar al agente en otra rama por un HEAD guardado.
            guard headConfirmed(ctx.branch, in: ctx.project) else {
                rt.status = .dormant
                awaitingHead.insert(id)
                return
            }
            guard isActive(ctx.branch, in: ctx.project) else { return }
        }
        rt.launchId = UUID()
        rt.isStopping = false
        rt.manuallyInterrupted = false
        rt.startupFailure = nil
        var plan = plan
        plan.environment["HIVE_LAUNCH_ID"] = rt.launchId.uuidString
        let terminal = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        TerminalTheme.apply(to: terminal)
        // El cursor toma el color del proyecto: así sabés en cuál estás de un vistazo.
        terminal.caretColor = ctx.project.tint.nsColor
        // En los agentes, /clear deja lo anterior en el scroll con una divisoria.
        terminal.preservesScrollbackOnClear = ctx.session.kind.isAgent
        terminal.capturesStartupOutput = ctx.session.kind == .codex
        terminal.restoreHistory(plan.restoredHistory, agent: ctx.session.kind)
        let events = TerminalEvents(
            onTitle: { [weak rt] title in rt?.title = title },
            onExit: { [weak self] terminal, code in self?.processExited(id, terminal: terminal, code: code) })
        terminal.processDelegate = events
        terminal.setProcessOutputHandler { [weak rt] in rt?.lastOutput = Date() }
        terminal.onUserInput = { [weak self, weak rt] data in
            guard let self, let rt, self.runtimes[id] === rt else { return }
            self.userInput(id, data)
        }

        var started = true
        if let binary = plan.binary {
            if let executable = environment.processes.resolve(binary, path: currentPATH) {
                environment.processes.start(terminal, executable: executable, args: plan.args, environment: plan.environmentList, directory: dir)
            } else {
                let kind = ctx.session.kind
                terminal.feed(text: "\r\n  No encontré `\(binary)` en tu PATH.\r\n\r\n  Para instalar \(kind.label):\r\n    \(kind.installHint)\r\n\r\n  Después tocá «Reintentar».\r\n")
                started = false
            }
        } else {
            environment.processes.start(terminal, executable: environment.loginShell, args: plan.args, environment: plan.environmentList, directory: dir)
        }

        let now = environment.now()
        projects.updateSession(id) { session in
            // El plan puede haber recuperado otro ID o descartado uno temporal que Codex no guardó.
            session.agentSessionId = plan.agentSessionId
            if started {
                session.lastLaunchedAt = now
                session.pendingWork = plan.continuesInterruptedWork ? PendingAgentWork(launchId: rt.launchId, since: now) : nil
            }
        }
        saveNow()
        rt.terminal = terminal
        rt.events = events
        rt.hooksSeen = false
        // Al relanzarse, el agente vuelve a arrancar en la carpeta de su rama.
        rt.workingDirectory = nil
        rt.workingSince = started && plan.continuesInterruptedWork ? now : nil
        rt.backgroundAgents = 0
        rt.status = started ? (plan.continuesInterruptedWork ? .working : .idle) : .exited(nil)
        if started && plan.continuesInterruptedWork {
            history.append(HistoryEntry(date: now, role: .marker, text: InterruptedWork.marker),
                           sessionId: id, agentName: ctx.session.kind.label)
            historyVersions[id, default: 0] += 1
            showNotice("Retomando la tarea interrumpida")
        }
    }

    var currentPATH: String {
        loginPATH ?? LoginShell.fallbackPATH(home: environment.home.path, inherited: environment.inheritedEnvironment["PATH"])
    }

    /// Reinicia una sesión. En un agente con el proceso vivo, primero lo corta y espera a que termine
    /// (como mucho 2 s): así no retoma la conversación mientras la anterior sigue escribiendo. Un shell
    /// interactivo ignora SIGTERM, así que ahí no se espera: se cierra al soltar su terminal.
    public func relaunch(_ id: UUID) {
        guard let rt = runtimes[id], !rt.isSwitchingAgent, !relaunching.contains(id) else { return }
        guard rt.kind.isAgent, rt.isRunning, let old = rt.terminal, old.isProcessRunning else {
            replaceTerminal(id)
            return
        }
        relaunching.insert(id)
        Task { [weak self] in
            guard let self else { return }
            defer { relaunching.remove(id) }
            await waitForExit(old)
            if old.isProcessRunning {
                old.hangUp()
                await waitForExit(old)
            }
            guard !isShuttingDown, runtimes[id] === rt, !rt.isStopping else { return }
            guard !old.isProcessRunning else {
                alert = AppAlert(title: "No pude reiniciar la sesión", message: "El proceso anterior sigue abierto. Detenelo y volvé a intentar.")
                return
            }
            replaceTerminal(id)
        }
    }

    private func replaceTerminal(_ id: UUID) {
        guard let rt = runtimes[id] else { return }
        tearDown(rt.terminal)
        rt.terminal = nil
        rt.events = nil
        rt.status = .dormant
        launch(id)
    }

    public func stop(_ id: UUID) {
        guard let rt = runtimes[id] else { return }
        clearPendingWork(id)
        rt.isStopping = true
        rt.isLaunching = false
        rt.isSwitchingAgent = false
        guard let terminal = rt.terminal else { return }
        // Un agente termina con SIGTERM (y guarda su conversación); el shell interactivo de una sesión
        // de Terminal lo ignora, así que se corta como al cerrar una ventana.
        if rt.kind.isAgent { terminal.terminate() } else { terminal.hangUp() }
    }

    /// Corta el proceso de una terminal y la saca de la pantalla.
    func tearDown(_ terminal: HiveTerminalView?) {
        terminal?.terminate()
        terminal?.removeFromSuperview()
    }

    /// Corta el proceso de una terminal y espera a que termine, como mucho `timeout` segundos.
    func waitForExit(_ terminal: HiveTerminalView, timeout: TimeInterval = 2) async {
        guard terminal.isProcessRunning else { return }
        let key = ObjectIdentifier(terminal)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exitWaiters[key, default: []].append(continuation)
            terminal.terminate()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resumeExitWaiters(key)
            }
        }
    }

    private func resumeExitWaiters(_ key: ObjectIdentifier) {
        for continuation in exitWaiters.removeValue(forKey: key) ?? [] { continuation.resume() }
    }

    func processExited(_ id: UUID, terminal: HiveTerminalView, code: Int32?) {
        resumeExitWaiters(ObjectIdentifier(terminal))
        // Ignoramos avisos de una terminal vieja que ya reemplazamos (o estamos reemplazando) al reiniciar.
        guard let rt = runtimes[id], rt.terminal === terminal else { return }
        if rt.kind == .codex, let code, code != 0,
           let failure = terminal.codexStartupFailure() {
            rt.startupFailure = failure
            if let draft = failure.unsentDraft {
                projects.updateSession(id) { $0.recoveredDraft = draft }
                // Antes de reemplazar la terminal, incluso si el fallo llegó al reiniciarla.
                saveNow()
            }
        }
        guard !relaunching.contains(id) else { return }
        if !isShuttingDown && code == 0 { clearPendingWork(id) }
        rt.status = .exited(code)
        rt.unseen = false
        updateBadge()
    }

    func discardRecoveredDraft(_ id: UUID) {
        projects.updateSession(id) { $0.recoveredDraft = nil }
        saveNow()
    }

    // MARK: - Continuar con otra IA

    public func requestSwitchAgent(_ id: UUID, to kind: SessionKind) {
        guard let ctx = sessionContext(id), ctx.session.kind.reportsConversation, kind.reportsConversation,
              ctx.session.kind != kind, !ctx.session.isArchived, let rt = runtimes[id],
              !rt.isLaunching, !rt.isSwitchingAgent, !relaunching.contains(id),
              isActive(ctx.branch, in: ctx.project), !removingBranches.contains(ctx.branch.id) else { return }
        guard let binary = kind.binary, environment.processes.resolve(binary, path: currentPATH) != nil else {
            alert = AgentAvailability.installAlert(for: kind)
            return
        }
        confirmInterruption(.switchAgent, of: id) { [weak self] in self?.switchAgent(id, to: kind) }
    }

    private func switchAgent(_ id: UUID, to kind: SessionKind) {
        guard let ctx = sessionContext(id), !ctx.session.isArchived, ctx.session.kind != kind,
              let rt = runtimes[id], !rt.isSwitchingAgent, !rt.isLaunching, !relaunching.contains(id),
              isActive(ctx.branch, in: ctx.project), !removingBranches.contains(ctx.branch.id) else { return }
        let directory = ctx.project.directory(for: ctx.branch)
        guard folderExists(directory, project: ctx.project, branch: ctx.branch, warnKey: id) else { return }
        rt.isSwitchingAgent = true
        Task { [weak self] in
            guard let self else { return }
            defer { rt.isSwitchingAgent = false }
            if let terminal = rt.terminal {
                await waitForExit(terminal)
                if terminal.isProcessRunning {
                    terminal.hangUp()
                    await waitForExit(terminal)
                }
                guard !terminal.isProcessRunning else {
                    alert = AppAlert(title: "No pude cambiar de IA", message: "El proceso anterior sigue abierto. Detenelo y volvé a intentar.")
                    return
                }
            }
            guard canFinishAgentSwitch(id, runtime: rt) else { return }
            let history = self.history
            let agents = environment.agents
            let now = environment.now()
            let claimed = projects.claimedAgentIds(ctx.session.kind, except: id)
            let place = ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)"
            do {
                try await Task.detached(priority: .userInitiated) {
                    try history.prepareHandoff(session: ctx.session, place: place, agents: agents,
                                               directory: directory, excluding: claimed, now: now)
                }.value
            } catch {
                if canFinishAgentSwitch(id, runtime: rt) {
                    alert = AppAlert(title: "No pude guardar el contexto para cambiar de IA", message: error.localizedDescription)
                }
                return
            }
            guard canFinishAgentSwitch(id, runtime: rt) else { return }
            history.append(HistoryEntry(date: now, role: .marker,
                                        text: AgentHandoff.markerPrefix + "\(ctx.session.kind.label) → \(kind.label)"),
                           sessionId: id, agentName: kind.label)
            historyVersions[id, default: 0] += 1
            tearDown(rt.terminal)
            rt.terminal = nil
            environment.notifier.clear(id)
            try? FileManager.default.removeItem(at: environment.paths.usageDir.appendingPathComponent("\(id.uuidString).json"))
            projects.updateSession(id) {
                $0.kind = kind
                // Los IDs nativos no son intercambiables entre proveedores. El historial de Hive sí.
                $0.agentSessionId = nil
                $0.lastLaunchedAt = nil
                $0.handoffFrom = ctx.session.kind
                $0.autoNamed = false
                $0.lastActivityAt = now
                $0.pendingWork = nil
            }
            runtimes[id] = SessionRuntime(sessionId: id, kind: kind)
            updateBadge()
            scheduleSave()
            launch(id)
            if selection == .session(id) { requestTerminalFocus(id) }
        }
    }

    private func canFinishAgentSwitch(_ id: UUID, runtime: SessionRuntime) -> Bool {
        guard runtime.isSwitchingAgent, runtimes[id] === runtime, let ctx = sessionContext(id) else { return false }
        return !ctx.session.isArchived && !removingBranches.contains(ctx.branch.id) && isActive(ctx.branch, in: ctx.project)
    }

    // MARK: - Confirmar antes de cortar

    /// Reiniciar desde un menú o con ⌘R: si cortaría algo en curso (ver `InterruptRule`), primero pregunta.
    public func requestRestart(_ id: UUID) {
        guard runtimes[id] != nil else { return }
        confirmInterruption(.restart, of: id) { [weak self] in self?.relaunch(id) }
    }

    /// Detener desde un menú o con ⌘.: si cortaría algo en curso, primero pregunta.
    public func requestStop(_ id: UUID) {
        guard runtimes[id] != nil else { return }
        confirmInterruption(.stop, of: id) { [weak self] in self?.stop(id) }
    }

    /// Lo que hay que confirmar antes de `action`, o nil si no corta nada en curso: un agente que
    /// trabaja o espera permiso, o una Terminal con un proceso en primer plano.
    func interruptConfirmation(_ action: SessionInterruption, of id: UUID) -> InterruptConfirmation? {
        guard let rt = runtimes[id], rt.isRunning, let ctx = sessionContext(id) else { return nil }
        return InterruptRule.confirmation(for: action, sessionName: ctx.session.name, isAgent: rt.kind.isAgent,
                                          status: rt.status, foregroundJob: rt.kind.isAgent ? nil : rt.terminal?.foregroundJob)
    }

    private func confirmInterruption(_ action: SessionInterruption, of id: UUID, perform: @escaping () -> Void) {
        guard let confirmation = interruptConfirmation(action, of: id) else {
            perform()
            return
        }
        alert = AppAlert(title: confirmation.title, message: confirmation.message, actionTitle: confirmation.actionTitle,
                         isDestructive: true, action: perform)
    }

    /// Sesiones de agente esperando tu permiso (a mitad de una herramienta): al salir también se cortan.
    var permissionCount: Int { runtimes.values.filter { $0.kind.isAgent && $0.isRunning && $0.status == .attention }.count }

    /// Sesiones de Terminal con un proceso en primer plano (un `npm run dev`, un build).
    var busyTerminalsCount: Int {
        runtimes.values.filter { !$0.kind.isAgent && $0.isRunning && $0.terminal?.foregroundJob != nil }.count
    }

    // MARK: - Archivar

    /// Archivar desde un menú, la X de la pestaña o con ⌘W: si cortaría algo en curso, primero pregunta.
    public func requestArchive(_ id: UUID) {
        guard runtimes[id] != nil else { return }
        confirmInterruption(.archive, of: id) { [weak self] in self?.archive(id) }
    }

    public func archive(_ id: UUID) {
        // Una ya archivada no se vuelve a archivar (le cambiaría la fecha y el deshacer la restauraría).
        guard let ctx = sessionContext(id), !ctx.session.isArchived else { return }
        clearPendingWork(id)
        if let rt = runtimes[id] {
            rt.isStopping = true
            rt.isLaunching = false
            rt.isSwitchingAgent = false
            tearDown(rt.terminal)
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
        let wasOpen = selection == .session(id)
        if wasOpen {
            select(neighbor.map { .session($0) } ?? .branch(ctx.branch.id))
        }
        offerUndo("Archivaste «\(ctx.session.name)»") { [weak self] in self?.restoreArchived(id, select: wasOpen) }
    }

    public func unarchive(_ id: UUID) {
        restoreArchived(id, select: true)
    }

    /// Saca una sesión del archivo; `select`: abrirla (si era la que estabas mirando).
    func restoreArchived(_ id: UUID, select reopen: Bool) {
        guard sessionContext(id)?.session.isArchived == true else { return }
        projects.updateSession(id) { $0.archivedAt = nil }
        if let ctx = sessionContext(id) { expanded.formUnion([ctx.project.id, ctx.branch.id]) }
        scheduleSave()
        if reopen { select(.session(id)) }
    }
}
