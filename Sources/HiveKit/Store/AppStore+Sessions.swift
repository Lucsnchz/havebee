import AppKit
import HiveCore

/// Sesiones: crear, lanzar, reiniciar, archivar.
extension AppStore {
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

    func createSession(branchId: UUID, kind: SessionKind) {
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

    /// Lanza el proceso de una sesión (agente o shell) en su terminal. Las búsquedas en disco
    /// (historial, MCP, conversaciones anteriores) corren fuera del hilo principal; la terminal se
    /// crea al volver, si la sesión sigue ahí y nadie la lanzó mientras tanto.
    func launch(_ id: UUID) {
        guard let ctx = sessionContext(id), let rt = runtimes[id], !rt.isRunning, !rt.isLaunching else { return }
        let dir = ctx.project.directory(for: ctx.branch)
        guard folderExists(dir, branch: ctx.branch, warnKey: id) else { return }
        let builder = launchContextBuilder(for: ctx.session, project: ctx.project, branch: ctx.branch, directory: dir)
        guard environment.launchesInBackground else {
            startSession(id, plan: LaunchPlanner.plan(builder.build()), directory: dir)
            return
        }
        rt.isLaunching = true
        Task { [weak self] in
            let context = await Task.detached(priority: .userInitiated) { builder.build() }.value
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
            claudeInline: settings.claudeInline, historyHint: settings.historyHint,
            claimedAgentIds: projects.claimedAgentIds(session.kind, except: session.id), now: environment.now())
    }

    /// Crea la terminal y arranca el proceso según el plan.
    private func startSession(_ id: UUID, plan: LaunchPlan, directory dir: String) {
        guard let ctx = sessionContext(id), let rt = runtimes[id] else { return }
        let terminal = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        TerminalTheme.apply(to: terminal)
        // El cursor toma el color del proyecto: así sabés en cuál estás de un vistazo.
        terminal.caretColor = ctx.project.tint.nsColor
        // En los agentes, /clear deja lo anterior en el scroll con una divisoria.
        terminal.preservesScrollbackOnClear = ctx.session.kind.isAgent
        let events = TerminalEvents(
            onTitle: { [weak self] title in self?.runtimes[id]?.title = title },
            onExit: { [weak self] terminal, code in self?.processExited(id, terminal: terminal, code: code) })
        terminal.processDelegate = events
        terminal.setProcessOutputHandler { [weak rt] in rt?.lastOutput = Date() }
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
        rt.events = events
        rt.hooksSeen = false
        rt.workingSince = nil
        rt.status = started ? .idle : .exited(nil)
    }

    var currentPATH: String {
        loginPATH ?? LoginShell.fallbackPATH(home: environment.home.path, inherited: environment.inheritedEnvironment["PATH"])
    }

    /// Reinicia una sesión. En un agente con el proceso vivo, primero lo corta y espera a que termine
    /// (como mucho 2 s): así no retoma la conversación mientras la anterior sigue escribiendo. Un shell
    /// interactivo ignora SIGTERM, así que ahí no se espera: se cierra al soltar su terminal.
    public func relaunch(_ id: UUID) {
        guard let rt = runtimes[id], !relaunching.contains(id) else { return }
        guard rt.kind.isAgent, rt.isRunning, let old = rt.terminal, old.isProcessRunning else {
            replaceTerminal(id)
            return
        }
        relaunching.insert(id)
        Task { [weak self] in
            await self?.waitForExit(old)
            self?.relaunching.remove(id)
            self?.replaceTerminal(id)
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
        runtimes[id]?.terminal?.terminate()
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
        guard let rt = runtimes[id], rt.terminal === terminal, !relaunching.contains(id) else { return }
        rt.status = .exited(code)
        rt.unseen = false
        updateBadge()
    }

    // MARK: - Archivar

    public func requestArchive(_ id: UUID) {
        guard let rt = runtimes[id] else { return }
        if rt.status == .working {
            alert = AppAlert(title: "La sesión está trabajando",
                             message: "Si la archivás se corta lo que está haciendo. La conversación queda guardada y la podés restaurar.",
                             actionTitle: "Archivar igual", isDestructive: true,
                             action: { [weak self] in self?.archive(id) })
        } else {
            archive(id)
        }
    }

    public func archive(_ id: UUID) {
        guard let ctx = sessionContext(id) else { return }
        if let rt = runtimes[id] {
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
        offerUndo("Archivaste “\(ctx.session.name)”") { [weak self] in self?.restoreArchived(id, select: wasOpen) }
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
