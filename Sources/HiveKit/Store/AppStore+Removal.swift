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
        case .session(let id):
            projects.updateSession(id) { session in
                session.name = name
                session.autoNamed = false // la nombraste vos: Hive no la vuelve a renombrar
            }
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
            // Qué pasa y qué no: lo de Hive se va (se puede deshacer unos segundos), el disco no se toca.
            let message = [stopping, "Sus ramas, sesiones y comandos se quitan de Hive. No se borra nada del disco: la carpeta y el repo quedan como están."]
            pendingRemoval = PendingRemoval(item: item, title: "¿Quitar «\(p.name)» de Hive?",
                                            message: message.compactMap { $0 }.joined(separator: " "), isWorktree: false)
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
            let archived = ctx.session.isArchived
            // Qué pasa al eliminarla y, si sigue abierta, la alternativa (el botón «Archivarla»).
            let message = switch (ctx.session.kind.reportsConversation, archived) {
            case (true, false): "Se cierra y se borra su historial en Hive (todo lo anterior a cada /clear). No se puede deshacer. Si lo querés conservar, archivala."
            case (false, false): "Se cierra su terminal y se quita de Hive. Si la querés conservar, archivala."
            // Ya archivada: no tiene sentido ofrecer archivarla.
            case (true, true): "Se borra su historial en Hive (todo lo anterior a cada /clear). No se puede deshacer."
            case (false, true): "Se borra de las archivadas. No se puede deshacer."
            }
            pendingRemoval = PendingRemoval(item: item, title: "¿Eliminar «\(ctx.session.name)»?", message: message, isWorktree: false,
                                            offersArchive: !archived)
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
                // Mientras se borra, sus sesiones no se pueden volver a abrir (arrancarían en esa carpeta).
                removingBranches.insert(id)
                defer { removingBranches.remove(id) }
                // Primero se corta lo que corre ahí, así nada escribe en la carpeta mientras git la borra.
                let terminals = ctx.branch.sessions.compactMap { runtimes[$0.id]?.terminal }
                    + commandRuns.filter { $0.branchId == id }.compactMap(\.terminal)
                stopSessions(ctx.branch.sessions.map(\.id))
                stopRuns { $0.branchId == id }
                await waitUntilStopped(terminals)
                // La limpieza del proyecto (polyscope.json o conductor.json) va antes de borrar la carpeta.
                // Al reintentar con «Borrar igual» ya corrió.
                if !force { await runArchiveScript(project: ctx.project, branch: ctx.branch, worktreePath: path) }
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
            guard let index = projects.firstIndex(where: { $0.id == id }), !projects[index].isScratch else { return false }
            let p = projects[index]
            terminate(p.allSessions.map(\.id))
            stopRuns { $0.projectId == id }
            let selectionWasInside = projects.contains(selection, inProject: id)
            projects.removeAll { $0.id == id }
            if selectionWasInside { select(nil) }
            scheduleSave()
            // Se lleva sus sesiones (con la conversación), las archivadas, los comandos, el color y el
            // ícono: volver a agregar el repo no los recupera, así que se puede deshacer.
            offerUndo("Quitaste «\(p.name)» de Hive") { [weak self] in
                self?.restoreProject(p, at: index, select: selectionWasInside)
            }
            return true
        }
    }

    /// Vuelve a poner un proyecto quitado (el «Deshacer»). Sus sesiones vuelven dormidas, con la
    /// conversación; los comandos que estaban corriendo quedaron cortados. Si mientras tanto volviste
    /// a agregar el mismo repo, no se duplica.
    func restoreProject(_ project: Project, at index: Int, select reopen: Bool) {
        guard !projects.contains(where: { $0.id == project.id || (!$0.isScratch && $0.path == project.path) }) else { return }
        projects.insert(project, at: min(index, projects.count))
        for session in project.allSessions where runtimes[session.id] == nil {
            runtimes[session.id] = SessionRuntime(sessionId: session.id, kind: session.kind)
        }
        gitGeneration += 1
        scheduleSave()
        // Al proyecto y no a la sesión que tenías abierta: abrirla la volvería a lanzar.
        if reopen { select(.project(project.id)) }
        refreshGit()
    }

    /// Corre el script de cierre del proyecto en el worktree (se ve en la esquinita) y espera a que
    /// termine, como mucho `archiveTimeout` segundos. Si falla o tarda de más, avisa y el borrado sigue.
    func runArchiveScript(project: Project, branch: Branch, worktreePath path: String) async {
        let projectPath = project.path
        let folder = (path as NSString).lastPathComponent
        // La rama no guarda su script de cierre: se vuelve a leer (puede haber cambiado desde que se creó).
        let command = await Task.detached(priority: .userInitiated) {
            ProjectScripts.resolve(projectPath: projectPath, folder: folder, mainHasCert: false).archive?.command
        }.value
        // Sin carpeta no hay nada que limpiar (y git solo poda el registro).
        guard let command, FileManager.default.fileExists(atPath: path),
              let runId = runScript(name: "Cerrar \(branch.name)", command: command, projectId: project.id, branchId: branch.id,
                                    environment: ProjectScripts.environment(rootPath: projectPath, worktreePath: path, branch: branch.name)),
              let run = commandRuns.first(where: { $0.id == runId }) else { return }
        let deadline = Date().addingTimeInterval(archiveTimeout)
        while run.running, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if run.running {
            // Como «Detener»: Ctrl+C y cortarlo aunque el shell ignore SIGTERM. Al quitar la rama se cierra su terminal.
            run.terminal?.sendInput([3])
            run.terminal?.hangUp()
            alert = AppAlert(title: "La limpieza de «\(branch.name)» tardó demasiado",
                             message: "\(command)\n\nLa corté a los \(Int(archiveTimeout)) s y seguí con el borrado del worktree.")
        } else if let code = run.exitCode, code != 0 {
            let output = Self.lastLines(run.terminal?.fullText() ?? "", count: 8)
            alert = AppAlert(title: "La limpieza de «\(branch.name)» terminó con error (código \(code))",
                             message: ([command, output].filter { !$0.isEmpty }).joined(separator: "\n\n")
                                + "\n\nSeguí con el borrado del worktree igual.")
        }
    }

    /// Las últimas líneas con texto de una salida (para mostrar en un aviso).
    static func lastLines(_ text: String, count: Int) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: "\n")
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

    /// Corta las sesiones pero las deja en Hive, dormidas (por si después no se pueden quitar). Una
    /// que se estaba armando para lanzarse ya no arranca.
    func stopSessions(_ ids: [UUID]) {
        for id in ids {
            guard let rt = runtimes[id] else { continue }
            rt.isLaunching = false
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
