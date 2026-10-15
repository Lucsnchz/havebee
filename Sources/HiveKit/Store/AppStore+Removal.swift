import AppKit
import HiveCore

/// Renombrar y quitar proyectos, ramas y sesiones.
extension AppStore {
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
            let stopping = Self.stoppingSummary(commands: commandRuns.filter { $0.projectId == id && $0.running }.count,
                                                sessions: p.allSessions.filter { runtimes[$0.id]?.isRunning == true }.count)
            pendingRemoval = PendingRemoval(item: item, title: "¿Quitar «\(p.name)» de Hive?",
                                            message: [stopping, "No se borra nada del disco."].compactMap { $0 }.joined(separator: " "),
                                            isWorktree: false)
        case .branch(let id):
            guard let ctx = branchContext(id) else { return }
            let worktree = ctx.branch.mode == .worktree
            let stopping = Self.stoppingSummary(commands: commandRuns.filter { $0.branchId == id && $0.running }.count,
                                                sessions: ctx.branch.sessions.filter { runtimes[$0.id]?.isRunning == true }.count)
            let message = [stopping, "La rama de git no se borra.",
                           worktree ? "Podés conservar el worktree en \(ctx.branch.worktreePath ?? "") o borrarlo." : nil]
                .compactMap { $0 }.joined(separator: " ")
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
                // Primero se corta lo que corre ahí, así nada escribe en la carpeta mientras git la borra.
                let terminals = ctx.branch.sessions.compactMap { runtimes[$0.id]?.terminal }
                    + commandRuns.filter { $0.branchId == id }.compactMap(\.terminal)
                stopSessions(ctx.branch.sessions.map(\.id))
                stopRuns { $0.branchId == id }
                await waitUntilStopped(terminals)
                let repo = ctx.project.path
                let git = self.git
                let r = await Task.detached { git.removeWorktree(path, force: force, in: repo) }.value
                guard r.ok else {
                    alert = AppAlert(title: "No se pudo borrar el worktree",
                                     message: "\(r.errorMessage)\n\n¿Borrarlo igual? Se pierden los cambios sin commitear.",
                                     actionTitle: "Borrar igual", isDestructive: true,
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
            stopRuns { $0.projectId == id }
            let selectionWasInside = projects.contains(selection, inProject: id)
            projects.removeAll { $0.id == id }
            if selectionWasInside { select(nil) }
            scheduleSave()
            return true
        }
    }

    func dropBranch(_ id: UUID) {
        guard let ctx = branchContext(id) else { return }
        terminate(ctx.branch.sessions.map(\.id))
        stopRuns { $0.branchId == id }
        let selectionWasInside = selection == .branch(id) || ctx.branch.sessions.contains(where: { selection == .session($0.id) })
        projects.updateProject(ctx.project.id) { $0.branches.removeAll { $0.id == id } }
        gitGeneration += 1
        scheduleSave()
        if selectionWasInside { select(.project(ctx.project.id)) }
        refreshGit()
    }

    /// «Se detienen 2 comandos y 1 sesión.» (nil si no corre nada).
    static func stoppingSummary(commands: Int, sessions: Int) -> String? {
        var parts: [String] = []
        if commands > 0 { parts.append(commands == 1 ? "1 comando" : "\(commands) comandos") }
        if sessions > 0 { parts.append(sessions == 1 ? "1 sesión" : "\(sessions) sesiones") }
        guard !parts.isEmpty else { return nil }
        return "\(commands + sessions == 1 ? "Se detiene" : "Se detienen") \(parts.joined(separator: " y "))."
    }

    /// Corta las sesiones pero las deja en Hive, dormidas (por si después no se pueden quitar).
    func stopSessions(_ ids: [UUID]) {
        for id in ids {
            guard let rt = runtimes[id] else { continue }
            tearDown(rt.terminal)
            rt.terminal = nil
            rt.events = nil
            rt.status = .dormant
            rt.unseen = false
            environment.notifier.clear(id)
        }
        updateBadge()
    }

    /// Espera a que terminen los procesos de unas terminales ya cortadas, como mucho `timeout` segundos.
    /// (Un shell interactivo ignora SIGTERM y se cierra recién al soltar su terminal: no lo esperamos de más.)
    func waitUntilStopped(_ terminals: [HiveTerminalView], timeout: TimeInterval = 1) async {
        let deadline = Date().addingTimeInterval(timeout)
        while terminals.contains(where: \.isProcessRunning), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func terminate(_ ids: [UUID]) {
        for id in ids {
            tearDown(runtimes[id]?.terminal)
            runtimes[id] = nil
            environment.notifier.clear(id)
        }
        updateBadge()
    }
}
