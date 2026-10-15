import AppKit
import HiveCore

/// Comandos del proyecto, MCP y diffs.
extension AppStore {
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
        guard folderExists(dir, branch: branch, warnKey: command.id) else { return }
        let run = CommandRun(projectId: project.id, branchId: branch.id, branchName: branch.name, commandId: command.id,
                             name: command.name, command: command.command, directory: dir)
        start(run)
        commandRuns.append(run)
        showRun(run.id)
    }

    func start(_ run: CommandRun) {
        let terminal = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), scrollback: 5_000)
        TerminalTheme.apply(to: terminal)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let runId = run.id
        let events = TerminalEvents(onExit: { [weak self] terminal, code in self?.commandExited(runId, terminal: terminal, code: code) })
        terminal.processDelegate = events
        let env = SessionEnvironment.base(inherited: environment.inheritedEnvironment, directory: run.directory, path: currentPATH)
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        // Shell interactivo de login: así carga nvm, aliases y lo que tengas en tu .zshrc.
        environment.processes.start(terminal, executable: environment.loginShell, args: ["-l", "-i", "-c", run.command],
                                    environment: env, directory: run.directory)
        run.terminal = terminal
        run.events = events
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
        tearDown(run.terminal)
        start(run)
    }

    public func closeRun(_ id: UUID) {
        guard let index = commandRuns.firstIndex(where: { $0.id == id }) else { return }
        tearDown(commandRuns[index].terminal)
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
}
