import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: proyectos, ramas y persistencia")
struct AppStoreProjectTests {
    @Test("Arranca vacío, con «Terminales»")
    func emptyStart() {
        let world = TestWorld()
        let store = world.makeStore()
        #expect(store.projects.map(\.name) == ["Terminales"])
        #expect(store.scratchProject?.path == world.home.path)
        #expect(store.repoProjects.isEmpty)
        #expect(store.selection == nil)
    }

    @Test("Agregar un repo: rama actual, color, selección y sin duplicados")
    func addProject() async throws {
        let world = TestWorld()
        let repo = GitRepo(branch: "trunk")
        world.logos[repo.path] = ["/logo.png"]
        let store = world.makeStore()
        await store.addProject(at: repo.path + "/") // con barra final
        let project = try #require(store.repoProjects.first)
        #expect(project.name == "repo")
        #expect(project.branches.map(\.name) == ["trunk"])
        #expect(project.color == .blue)
        #expect(project.icon == .image("/logo.png"))
        #expect(store.projects.last?.isScratch == true)
        #expect(store.selection == .branch(project.branches[0].id))
        #expect(store.isExpanded(project.id))

        // Desde una subcarpeta, el mismo repo: no se duplica, se selecciona.
        repo.write("src/a.txt", "x")
        await store.addProject(at: repo.path + "/src")
        #expect(store.repoProjects.count == 1)
        #expect(store.selection == .project(project.id))

        // Un segundo repo recibe otro color.
        let second = GitRepo(name: "segundo")
        await store.addProject(at: second.path)
        #expect(store.repoProjects.map(\.color) == [.blue, .orange])
    }

    @Test("Agregar una carpeta sin git ofrece inicializarlo")
    func addNonRepository() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let folder = TempDir()
        await store.addProject(at: folder.path)
        let alert = try #require(store.alert)
        #expect(alert.title == "No es un repositorio git")
        #expect(store.repoProjects.isEmpty)
        alert.action?()
        #expect(await waitUntil { store.repoProjects.count == 1 })
        #expect(FileManager.default.fileExists(atPath: folder.path + "/.git"))
    }

    @Test("Importa los worktrees que ya existían")
    func importsWorktrees() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let external = repo.dir.url.path + "/externo"
        repo.sh("git worktree add -q -b externa \(shellQuote(external))")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let branches = try #require(store.repoProjects.first?.branches)
        #expect(branches.map(\.name) == ["main", "externa"])
        #expect(branches[1].mode == .worktree && branches[1].worktreePath == external)
    }

    @Test("Guarda y vuelve a cargar todo")
    func persistence() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        store.setColor(.pink, project: project.id)
        store.saveCommand(projectId: project.id, commandId: nil, name: "Dev", command: "npm run dev")
        let sessionId = try #require(store.repoProjects.first?.allSessions.first?.id)

        let reloaded = world.makeStore()
        #expect(reloaded.projects == store.projects)
        #expect(reloaded.selection == .session(sessionId))
        #expect(reloaded.runtimes[sessionId]?.status == .dormant)
        #expect(reloaded.isExpanded(project.id))
        #expect(reloaded.mainHead(of: project.id) == "main") // guardada: no hace falta leer git al cargar
        reloaded.select(.project(project.id))
        reloaded.openProject(project.id)
        #expect(reloaded.selection == .session(sessionId)) // recordó la última sesión
    }

    @Test("Un estado roto se aparta y se arranca de cero")
    func corruptedState() async throws {
        let world = TestWorld()
        try FileManager.default.createDirectory(at: world.paths.root, withIntermediateDirectories: true)
        try "{roto".write(to: world.paths.stateFile, atomically: true, encoding: .utf8)
        let store = world.makeStore()
        #expect(store.repoProjects.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: world.paths.root.path).filter { $0.hasSuffix(".bak.json") }
        #expect(backups.count == 1)
    }

    @Test("Migra un estado viejo: colores, «Terminales» al final y sesiones dormidas")
    func migratesLegacyState() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let session = Session(name: "Claude 1", kind: .claude)
        let legacy = HiveState(projects: [.scratch(home: "/h"), Project(name: "viejo", path: repo.path, branches: [Branch(name: "main", mode: .main, sessions: [session])])])
        try StateStore(file: world.paths.stateFile).save(legacy)
        let store = world.makeStore()
        #expect(store.projects.map(\.name) == ["viejo", "Terminales"])
        #expect(store.repoProjects.first?.color == .blue)
        #expect(store.repoProjects.first?.icon == .initials)
        #expect(store.runtimes[session.id]?.status == .dormant)
        // Al cargar no se lee git: el estado viejo no tenía la rama y la trae la primera revisión.
        #expect(store.mainHead(of: store.repoProjects[0].id) == "")
        await store.refreshGitNow()
        #expect(store.mainHead(of: store.repoProjects[0].id) == "main")
    }

    @Test("Crear una rama en worktree, con primera sesión")
    func createWorktreeBranch() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        let error = await store.createBranch(NewBranchRequest(projectId: project.id, name: "feature/x", isNew: true, base: "main", mode: .worktree, firstSession: .claude))
        #expect(error == nil)
        let branch = try #require(store.project(project.id)?.branches.last)
        #expect(branch.name == "feature/x" && branch.mode == .worktree)
        #expect(FileManager.default.fileExists(atPath: try #require(branch.worktreePath)))
        #expect(branch.sessions.map(\.name) == ["Claude 1"])
        #expect(store.selection == .session(branch.sessions[0].id))
    }

    @Test("Los errores al crear una rama se devuelven sin tocar nada")
    func createBranchErrors() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        let error = await store.createBranch(NewBranchRequest(projectId: project.id, name: "main", isNew: true, mode: .worktree))
        #expect(error == "La rama «main» ya está en Havebee.")
        #expect(await store.createBranch(NewBranchRequest(projectId: UUID(), name: "x", isNew: true, mode: .main)) == "No encontré el proyecto.")
        #expect(store.project(project.id)?.branches.count == 1)
    }

    @Test("Rama en la carpeta principal: pide checkout, lo hace y crea la sesión")
    func checkoutFlow() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.createBranch(NewBranchRequest(projectId: project.id, name: "fix", isNew: true, mode: .main)) == nil)
        let fix = try #require(store.project(project.id)?.branches.first { $0.name == "fix" })
        #expect(!store.isActive(fix, in: try #require(store.project(project.id))))

        repo.write("README.md", "sucio")
        await store.refreshGitNow()
        store.requestNewSession(branchId: fix.id, kind: .codex)
        let pending = try #require(store.pendingCheckout)
        #expect(pending.branchName == "fix" && pending.currentHead == "main")
        #expect(pending.after == .createSession(.codex))
        #expect(pending.dirty)
        #expect(pending.message.contains("La carpeta principal está en «main»"))
        #expect(pending.message.contains("Hay cambios sin commitear"))
        #expect(fix.sessions.isEmpty)

        #expect(await store.performCheckout(pending))
        #expect(store.mainHead(of: project.id) == "fix")
        #expect(repo.git.currentBranch(repo.path) == "fix")
        #expect(store.project(project.id)?.branches.first { $0.name == "fix" }?.sessions.map(\.name) == ["Codex 1"])
    }

    @Test("Si el checkout falla queda una alerta")
    func checkoutFailure() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.createBranch(NewBranchRequest(projectId: project.id, name: "otra", isNew: true, mode: .main)) == nil)
        let otra = try #require(store.project(project.id)?.branches.first { $0.name == "otra" })
        repo.sh("git branch -D otra") // alguien la borró por fuera
        store.requestCheckout(branchId: otra.id)
        #expect(!(await store.performCheckout(try #require(store.pendingCheckout))))
        #expect(store.alert?.title == "No pude hacer checkout de «otra»")
    }

    @Test("Detecta checkouts y worktrees hechos por fuera")
    func refreshGit() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        repo.sh("git checkout -q -b otra")
        repo.sh("git worktree add -q -b de-afuera \(shellQuote(repo.dir.url.path + "/afuera"))")
        repo.write("nuevo.txt", "x")
        await store.refreshGitNow()
        #expect(store.mainHead(of: project.id) == "otra")
        let updated = try #require(store.project(project.id))
        #expect(updated.branches.map(\.name).contains("de-afuera"))
        let main = updated.branches[0]
        #expect(!store.isActive(main, in: updated)) // la carpeta principal ya no está en main
        #expect(store.gitStatus(for: main, in: updated) == nil)
    }

    @Test("Un worktree borrado por fuera desaparece solo de Hive, con la selección y sus sesiones")
    func worktreeDeletedOutside() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        _ = await store.createBranch(NewBranchRequest(projectId: project.id, name: "efimera", isNew: true, mode: .worktree))
        let branch = try #require(store.project(project.id)?.branches.last)
        store.requestNewSession(branchId: branch.id, kind: .claude)
        let session = try #require(store.project(project.id)?.branches.last?.sessions.first)
        store.select(.session(session.id))
        let path = try #require(branch.worktreePath)
        repo.sh("git worktree remove --force \(shellQuote(path)) && git branch -D efimera")
        await store.refreshGitNow()
        #expect(store.project(project.id)?.branches.map(\.name) == ["main"])
        #expect(store.runtimes[session.id] == nil)
        #expect(store.selection == .project(project.id))
    }

    @Test("Quitar una rama: el worktree se conserva y no vuelve a aparecer")
    func removeBranchKeepingWorktree() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        _ = await store.createBranch(NewBranchRequest(projectId: project.id, name: "temporal", isNew: true, mode: .worktree))
        let branch = try #require(store.project(project.id)?.branches.last)
        #expect(await store.performRemove(.branch(branch.id)))
        #expect(store.project(project.id)?.branches.map(\.name) == ["main"])
        #expect(FileManager.default.fileExists(atPath: try #require(branch.worktreePath)))
        await store.refreshGitNow()
        #expect(store.project(project.id)?.branches.map(\.name) == ["main"]) // ignorado
        #expect(store.selection == .project(project.id))
    }

    @Test("Quitar una rama borrando su worktree; forzar exige revisión y nombre escrito")
    func removeBranchDeletingWorktree() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        _ = await store.createBranch(NewBranchRequest(projectId: project.id, name: "sucia", isNew: true, mode: .worktree))
        let branch = try #require(store.project(project.id)?.branches.last)
        let path = try #require(branch.worktreePath)
        try "cambio".write(toFile: path + "/nuevo.txt", atomically: true, encoding: .utf8)
        store.requestNewSession(branchId: branch.id, kind: .shell)
        let session = try #require(store.project(project.id)?.branches.last?.sessions.first)
        store.activate(session.id)
        #expect(store.runtimes[session.id]?.isRunning == true)

        #expect(!(await store.performRemove(.branch(branch.id), deleteWorktree: true)))
        #expect(store.alert?.actionTitle == nil)
        #expect(store.alert?.message.contains("escribir el nombre de la rama") == true)
        #expect(store.project(project.id)?.branches.count == 2)
        // Las sesiones se cortaron antes de intentar borrar, pero siguen en Hive (dormidas).
        #expect(store.runtimes[session.id]?.status == .dormant)
        #expect(store.runtimes[session.id]?.isRunning == false)

        let review = try #require(await store.removalReview(branchId: branch.id))
        #expect(await store.performRemove(.branch(branch.id), deleteWorktree: true, force: true, review: review, confirmation: "sucia"))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(store.project(project.id)?.branches.count == 1)
        #expect(store.runtimes[session.id] == nil)
    }

    @Test("Quitar un proyecto cierra sus sesiones; «Terminales» no se puede quitar")
    func removeProject() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = GitRepo()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .shell)
        let session = try #require(store.repoProjects.first?.allSessions.first)
        #expect(await store.performRemove(.project(project.id)))
        #expect(store.repoProjects.isEmpty)
        #expect(store.runtimes[session.id] == nil)
        #expect(store.selection == nil)
        let scratch = try #require(store.scratchProject)
        #expect(!(await store.performRemove(.project(scratch.id))))
        store.requestRemoval(.project(scratch.id))
        #expect(store.pendingRemoval == nil)
    }

    @Test("Textos de confirmación al quitar")
    func removalPrompts() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        _ = await store.createBranch(NewBranchRequest(projectId: project.id, name: "wt", isNew: true, mode: .worktree))
        let worktree = try #require(store.project(project.id)?.branches.last)
        #expect(worktree.worktreePath != nil)
        store.requestRemoval(.branch(worktree.id))
        #expect(store.pendingRemoval?.isWorktree == true)
        #expect(store.pendingRemoval?.message == "Podés quitarlo de Havebee conservando la carpeta, o borrar el worktree del disco.")
        store.requestRemoval(.branch(project.branches[0].id))
        #expect(store.pendingRemoval?.isWorktree == false)
        #expect(store.pendingRemoval?.message == "La rama de git no se borra.")
        store.requestRemoval(.project(project.id))
        #expect(store.pendingRemoval?.title == "¿Quitar «repo» de Havebee?")
        #expect(store.pendingRemoval?.message == "Sus ramas, sesiones y comandos se quitan de Havebee. No se borra nada del disco: la carpeta y el repo quedan como están.")

        // Con cosas corriendo, dice qué se va a detener.
        store.requestNewSession(branchId: worktree.id, kind: .shell)
        let session = try #require(store.project(project.id)?.branches.last?.sessions.first)
        store.activate(session.id)
        store.saveCommand(projectId: project.id, commandId: nil, name: "Dev", command: "npm run dev")
        store.saveCommand(projectId: project.id, commandId: nil, name: "Cola", command: "php artisan queue:work")
        for command in try #require(store.project(project.id)?.commands) { store.run(command.id, projectId: project.id, branchId: worktree.id) }
        store.requestRemoval(.branch(worktree.id))
        #expect(store.pendingRemoval?.message == "Se detienen 2 comandos y 1 sesión. Podés quitarlo de Havebee conservando la carpeta, o borrar el worktree del disco.")
        store.requestRemoval(.project(project.id))
        #expect(store.pendingRemoval?.message == "Se detienen 2 comandos y 1 sesión. Sus ramas, sesiones y comandos se quitan de Havebee. No se borra nada del disco: la carpeta y el repo quedan como están.")
        #expect(AppStore.stoppingSummary(commands: 1, sessions: 0) == "Se detiene 1 comando.")
        #expect(AppStore.stoppingSummary(commands: 0, sessions: 3) == "Se detienen 3 sesiones.")
        #expect(AppStore.stoppingSummary(commands: 0, sessions: 0) == nil)

        // Eliminar una sesión avisa que se va su historial y sugiere archivarla.
        store.requestRemoval(.session(session.id))
        #expect(store.pendingRemoval?.title == "¿Eliminar «Terminal 1»?")
        #expect(store.pendingRemoval?.message == "Se cierra su terminal y se quita de Havebee. Si la querés conservar, archivala.")
        store.requestNewSession(branchId: worktree.id, kind: .claude)
        let claude = try #require(store.project(project.id)?.branches.last?.sessions.last)
        store.requestRemoval(.session(claude.id))
        #expect(store.pendingRemoval?.message == "Se cierra y se borra su historial en Havebee (todo lo anterior a cada /clear). No se puede deshacer. Si lo querés conservar, archivala.")
    }

    @Test("Renombrar, colores, apariencia y orden")
    func editing() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = GitRepo()
        let second = GitRepo(name: "segundo")
        await store.addProject(at: repo.path)
        await store.addProject(at: second.path)
        let first = try #require(store.repoProjects.first)
        store.beginRename(.project(first.id))
        #expect(store.renameText == "repo")
        store.renameText = "  Tienda  "
        store.commitRename(try #require(store.rename))
        #expect(store.project(first.id)?.name == "Tienda")
        store.renameText = "   "
        store.commitRename(RenameRequest(item: .project(first.id)))
        #expect(store.project(first.id)?.name == "Tienda") // un nombre vacío no se aplica
        store.beginRename(.branch(first.branches[0].id))
        #expect(store.rename?.item != .branch(first.branches[0].id)) // las ramas no se renombran

        store.updateAppearance(projectId: first.id, name: "Shop", color: .lime, icon: .emoji("🛒"))
        #expect(store.project(first.id)?.name == "Shop" && store.project(first.id)?.icon == .emoji("🛒"))
        store.setColor(.red, branch: first.branches[0].id)
        #expect(store.project(first.id)?.branches[0].color == .red)

        store.move(.project(first.id), by: 1)
        #expect(store.projects.map(\.name) == ["segundo", "Shop", "Terminales"])
        store.moveProjects(from: [1], to: 0)
        #expect(store.projects.map(\.name) == ["Shop", "segundo", "Terminales"])
        #expect(try #require(store.position(of: .project(first.id))) == (0, 2))
    }

    @Test("Personalizar con una imagen propia la copia a la carpeta de Hive")
    func importIcon() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let folder = TempDir()
        let source = folder.write("logo.png", "png")
        let copied = try #require(store.importIcon(from: source))
        #expect(copied.hasPrefix(world.paths.iconsDir.path))
        #expect(FileManager.default.fileExists(atPath: copied))
        #expect(store.importIcon(from: URL(fileURLWithPath: "/no/existe.png")) == nil)
        #expect(store.alert?.title == "No pude usar la imagen")
    }
}

@MainActor
@Suite("Store: sesiones y agentes")
struct AppStoreSessionTests {
    /// Un store con un repo y su rama principal activa.
    @MainActor
    struct Setup {
        let world: TestWorld
        let repo: GitRepo
        let store: AppStore
        let project: Project
        var branchId: UUID { project.branches[0].id }

        init() async throws {
            world = TestWorld()
            repo = GitRepo()
            store = world.makeStore()
            await store.addProject(at: repo.path)
            project = try #require(store.repoProjects.first)
        }

        func newSession(_ kind: SessionKind) throws -> Session {
            store.requestNewSession(branchId: branchId, kind: kind)
            return try #require(store.project(project.id)?.branches[0].sessions.last)
        }
    }

    @Test("Nombres de sesión y selección")
    func createSessions() async throws {
        let s = try await Setup()
        let first = try s.newSession(.claude)
        let second = try s.newSession(.claude)
        let shell = try s.newSession(.shell)
        #expect([first.name, second.name, shell.name] == ["Claude 1", "Claude 2", "Terminal 1"])
        #expect(s.store.selection == .session(shell.id))
        #expect(s.store.runtimes[first.id]?.status == .dormant)
        #expect(s.store.currentProjectId == s.project.id)
    }

    @Test("Al abrirla, Claude arranca con su ID, hooks, historial y MCP")
    func launchClaude() async throws {
        let s = try await Setup()
        try "{\"mcpServers\": {\"boost\": {\"command\": \"php\"}}}".write(toFile: s.repo.path + "/.mcp.json", atomically: true, encoding: .utf8)
        let session = try s.newSession(.claude)
        s.store.activate(session.id)
        let launch = try #require(s.world.processes.launches.last)
        #expect(launch.executable == "/fake/bin/claude")
        #expect(launch.directory == s.repo.path)
        let agentId = try #require(s.store.sessionContext(session.id)?.session.agentSessionId)
        #expect(Array(launch.args.prefix(2)) == ["--session-id", agentId])
        // «Mostrar uso de Claude en su barra» está prendido por defecto: los ajustes con statusLine.
        #expect(launch.args.contains(s.world.paths.claudeSettingsWithUsage.path))
        #expect(launch.args.contains("--append-system-prompt"))
        #expect(launch.environment["HIVE_SESSION_ID"] == session.id.uuidString)
        #expect(launch.environment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] == "1")
        #expect(launch.environment["CLAUDECODE"] == nil)
        #expect(launch.environment["PATH"] == "/fake/bin:/usr/bin:/bin")
        #expect(s.store.runtimes[session.id]?.status == .idle)
        #expect(s.store.runtimes[session.id]?.isRunning == true)
        #expect(s.store.sessionContext(session.id)?.session.lastLaunchedAt == s.world.now)
        // El archivo de historial existe desde el arranque, para que la IA lo encuentre.
        #expect(FileManager.default.fileExists(atPath: s.store.history.markdownURL(session.id).path))
        // Abrirla de nuevo no la relanza.
        s.store.activate(session.id)
        #expect(s.world.processes.launches.count == 1)
    }

    @Test("El uso de Claude en su barra: encadena el statusLine del usuario y, apagado, usa los ajustes de siempre")
    func launchClaudeUsage() async throws {
        let s = try await Setup()
        try #"{"statusLine": {"type": "command", "command": "npx ccstatusline"}}"#
            .write(to: s.world.agents.claudeConfigDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let on = try s.newSession(.claude)
        s.store.activate(on.id)
        let launch = try #require(s.world.processes.launches.last)
        #expect(launch.args.contains(s.world.paths.claudeSettingsWithUsage.path))
        #expect(launch.environment["HIVE_USER_STATUSLINE"] == "npx ccstatusline")

        s.world.settings.showClaudeUsage = false
        let off = try s.newSession(.claude)
        s.store.activate(off.id)
        let plain = try #require(s.world.processes.launches.last)
        #expect(plain.args.contains(s.world.paths.claudeSettings.path))
        #expect(!plain.args.contains(s.world.paths.claudeSettingsWithUsage.path))
        #expect(plain.environment["HIVE_USER_STATUSLINE"] == nil)
    }

    @Test("Codex y Gemini reciben los MCP del proyecto")
    func launchCodexAndGemini() async throws {
        let s = try await Setup()
        try "{\"mcpServers\": {\"boost\": {\"command\": \"php\", \"args\": [\"artisan\"]}}}".write(toFile: s.repo.path + "/.mcp.json", atomically: true, encoding: .utf8)
        let codex = try s.newSession(.codex)
        s.store.activate(codex.id)
        #expect(s.world.processes.launches.last?.args.contains(#"mcp_servers.boost.command="php""#) == true)
        let gemini = try s.newSession(.gemini)
        s.store.activate(gemini.id)
        let settingsPath = try #require(s.world.processes.launches.last?.environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"])
        #expect(FileManager.default.fileExists(atPath: settingsPath))
    }

    @Test("La terminal usa el shell de login")
    func launchShell() async throws {
        let s = try await Setup()
        let shell = try s.newSession(.shell)
        s.store.activate(shell.id)
        let launch = try #require(s.world.processes.launches.last)
        #expect(launch.executable == "/bin/zsh" && launch.args == ["-l"])
        #expect(!FileManager.default.fileExists(atPath: s.store.history.markdownURL(shell.id).path))
    }

    @Test("Si el agente no está instalado, la sesión queda terminada")
    func missingBinary() async throws {
        let s = try await Setup()
        s.world.processes.installed = []
        let session = try s.newSession(.gemini)
        s.store.activate(session.id)
        #expect(s.world.processes.launches.isEmpty)
        #expect(s.store.runtimes[session.id]?.status == .exited(nil))
    }

    @Test("Una sesión de una rama inactiva no se lanza sola")
    func inactiveBranchDoesNotLaunch() async throws {
        let s = try await Setup()
        let session = try s.newSession(.claude)
        s.repo.sh("git checkout -q -b otra")
        await s.store.refreshGitNow()
        s.store.activate(session.id)
        #expect(s.world.processes.launches.isEmpty)
        s.store.openInactiveSession(session.id)
        #expect(s.store.pendingCheckout?.after == .openSession(session.id))
    }

    @Test("Stop de Claude: te toca, aviso, globito, tarjeta e historial")
    func stopEvent() async throws {
        let s = try await Setup()
        let session = try s.newSession(.claude)
        s.store.activate(session.id)
        s.store.select(.branch(s.branchId)) // no la estás mirando
        s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Hacé el login"])])
        #expect(s.store.runtimes[session.id]?.status == .working)
        s.world.advance(30)
        s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "Listo, hice el login."])])

        let rt = try #require(s.store.runtimes[session.id])
        #expect(rt.status == .waiting && rt.unseen)
        #expect(s.world.badge == "1")
        let post = try #require(s.world.notifier.posts.last)
        #expect(post.title == "repo › main")
        #expect(post.subtitle == "Hacé el login · Tu turno") // tomó el nombre del primer pedido
        #expect(post.body == "Listo, hice el login.")
        let updated = try #require(s.store.sessionContext(session.id)?.session)
        #expect(updated.lastMessage == "Listo, hice el login.")
        #expect(updated.lastActivityAt == s.world.now)
        #expect(s.store.history.load(session.id).map(\.text) == ["Hacé el login", "Listo, hice el login."])
        #expect(s.store.activity(of: try #require(s.store.project(s.project.id))) == Activity(pending: 1))

        // Al mirarla se marca como vista y se borra el aviso.
        s.store.select(.session(session.id))
        s.store.activate(session.id)
        #expect(!rt.unseen)
        #expect(s.world.badge == nil)
        #expect(s.world.notifier.cleared.contains(session.id))
    }

    @Test("Si la estás mirando no avisa")
    func focusedNoNotification() async throws {
        let s = try await Setup()
        let session = try s.newSession(.claude)
        s.store.activate(session.id)
        s.world.appActive = true
        s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "Stop", payload: [:])])
        #expect(s.store.runtimes[session.id]?.status == .waiting)
        #expect(s.store.runtimes[session.id]?.unseen == false)
        #expect(s.world.notifier.posts.isEmpty)
    }

    @Test("Permiso, /clear y Codex")
    func otherEvents() async throws {
        let s = try await Setup()
        let claude = try s.newSession(.claude)
        let codex = try s.newSession(.codex)
        s.store.activate(claude.id)
        s.store.activate(codex.id)
        s.store.select(nil)

        s.store.handle([HiveEvent(sessionId: claude.id, source: "claude", name: "Notification", payload: ["notification_type": "permission_prompt", "message": "Permiso para Bash"])])
        #expect(s.store.runtimes[claude.id]?.status == .attention)
        #expect(s.world.notifier.posts.last?.subtitle == "Claude 1 · Necesita permiso")
        #expect(s.store.activity(of: try #require(s.store.project(s.project.id))).attention == 1)

        s.store.handle([HiveEvent(sessionId: claude.id, source: "claude", name: "SessionStart", payload: ["session_id": "nuevo-id", "source": "clear"])])
        #expect(s.store.sessionContext(claude.id)?.session.agentSessionId == "nuevo-id")
        #expect(s.store.history.load(claude.id).last?.role == .marker)

        s.store.handle([HiveEvent(sessionId: codex.id, source: "codex", name: "notify",
                                  payload: ["type": "agent-turn-complete", "thread-id": "t-1", "input-messages": ["Hola"], "last-assistant-message": "Chau"])])
        #expect(s.store.sessionContext(codex.id)?.session.agentSessionId == "t-1")
        #expect(s.store.runtimes[codex.id]?.status == .waiting)
        #expect(s.store.history.load(codex.id).map(\.text) == ["Hola", "Chau"])
        #expect((s.store.historyVersions[codex.id] ?? 0) > 0)
    }

    @Test("Los eventos de sesiones que no corren se ignoran")
    func ignoredEvents() async throws {
        let s = try await Setup()
        let session = try s.newSession(.claude) // dormida
        s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "Stop", payload: [:]),
                        HiveEvent(sessionId: UUID(), source: "claude", name: "Stop", payload: [:])])
        #expect(s.store.runtimes[session.id]?.status == .dormant)
        #expect(s.world.notifier.posts.isEmpty)
    }

    @Test("Enter empieza a trabajar; el silencio lo termina")
    func inputAndSilence() async throws {
        let s = try await Setup()
        let session = try s.newSession(.codex)
        s.store.activate(session.id)
        s.store.select(nil)
        let rt = try #require(s.store.runtimes[session.id])

        s.store.userInput(session.id, Array("hola".utf8)[...])
        #expect(rt.status == .idle) // sin Enter no pasa nada
        s.store.userInput(session.id, [13])
        #expect(rt.status == .working)

        // Salida durante 10 segundos y después silencio.
        rt.lastOutput = s.world.now.addingTimeInterval(10)
        s.world.advance(12)
        s.store.tick()
        #expect(rt.status == .working)
        s.world.advance(5)
        s.store.tick()
        #expect(rt.status == .waiting)
        #expect(s.world.notifier.posts.last?.body == "Espera tu respuesta.") // Codex sin eventos: avisa el silencio

        // Escribir en una sesión pendiente la marca como vista.
        s.store.userInput(session.id, Array("x".utf8)[...])
        #expect(!rt.unseen)
    }

    @Test("Una terminal vieja que termina no pisa a la nueva")
    func staleTermination() async throws {
        let s = try await Setup()
        let session = try s.newSession(.shell)
        s.store.activate(session.id)
        let rt = try #require(s.store.runtimes[session.id])
        let old = try #require(rt.terminal)
        s.store.relaunch(session.id)
        #expect(rt.terminal !== old)
        s.store.processExited(session.id, terminal: old, code: 1)
        #expect(rt.status == .idle)
        s.store.processExited(session.id, terminal: try #require(rt.terminal), code: 2)
        #expect(rt.status == .exited(2))
        #expect(!rt.isRunning)
    }

    @Test("Archivar y restaurar")
    func archive() async throws {
        let s = try await Setup()
        let first = try s.newSession(.claude)
        let second = try s.newSession(.shell)
        s.store.activate(first.id)
        s.store.select(.session(first.id))
        s.store.archive(first.id)
        #expect(s.store.sessionContext(first.id)?.session.archivedAt == s.world.now)
        #expect(s.store.runtimes[first.id]?.status == .dormant)
        #expect(s.store.runtimes[first.id]?.isRunning == false)
        #expect(s.store.selection == .session(second.id)) // la pestaña de al lado
        #expect(s.store.project(s.project.id)?.activeSessions.map(\.id) == [second.id])

        s.store.unarchive(first.id)
        #expect(s.store.sessionContext(first.id)?.session.isArchived == false)
        #expect(s.store.selection == .session(first.id))
    }

    @Test("Archivar una sesión que trabaja pide confirmación")
    func archiveWorking() async throws {
        let s = try await Setup()
        let session = try s.newSession(.claude)
        s.store.activate(session.id)
        s.store.userInput(session.id, [13])
        s.store.requestArchive(session.id)
        #expect(s.store.alert?.actionTitle == "Archivar igual")
        #expect(s.store.sessionContext(session.id)?.session.isArchived == false)
        s.store.alert?.action?()
        #expect(s.store.sessionContext(session.id)?.session.isArchived == true)
    }

    @Test("Eliminar una sesión borra su historial")
    func removeSession() async throws {
        let s = try await Setup()
        let session = try s.newSession(.claude)
        s.store.activate(session.id)
        s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "x"])])
        #expect(await s.store.performRemove(.session(session.id)))
        #expect(s.store.sessionContext(session.id) == nil)
        #expect(s.store.runtimes[session.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: s.store.history.jsonlURL(session.id).path))
        #expect(s.store.selection == .branch(s.branchId))
    }

    @Test("Ordenar sesiones deja las archivadas al final")
    func reorderSessions() async throws {
        let s = try await Setup()
        let a = try s.newSession(.claude), b = try s.newSession(.codex), c = try s.newSession(.shell)
        s.store.archive(b.id)
        s.store.moveSessions(in: s.branchId, from: [1], to: 0)
        #expect(s.store.project(s.project.id)?.branches[0].sessions.map(\.id) == [c.id, a.id, b.id])
        s.store.move(.session(c.id), by: 1)
        #expect(s.store.project(s.project.id)?.branches[0].sessions.map(\.id) == [a.id, c.id, b.id])
    }

    @Test("Abrir un proyecto va a su última sesión, o a la más reciente, o al resumen")
    func openProject() async throws {
        let s = try await Setup()
        s.store.openProject(s.project.id)
        #expect(s.store.selection == .project(s.project.id))
        let a = try s.newSession(.claude)
        _ = try s.newSession(.codex)
        s.store.select(.session(a.id))
        s.store.select(nil)
        s.store.openProject(s.project.id)
        #expect(s.store.selection == .session(a.id))
    }
}

@MainActor
@Suite("Store: comandos, MCP y diffs")
struct AppStoreToolsTests {
    @Test("Comandos: guardar, editar, correr en la rama abierta y cerrar")
    func commands() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.saveCommand(projectId: project.id, commandId: nil, name: "  ", command: " npm run dev ")
        let command = try #require(store.project(project.id)?.commands.first)
        #expect(command.name == "npm run dev" && command.command == "npm run dev") // sin nombre usa el comando
        store.saveCommand(projectId: project.id, commandId: command.id, name: "Dev", command: "npm run dev -- --port 3000")
        #expect(store.project(project.id)?.commands.first?.name == "Dev")
        store.saveCommand(projectId: project.id, commandId: nil, name: "x", command: "   ")
        #expect(store.project(project.id)?.commands.count == 1) // un comando vacío no se guarda

        store.run(command.id, projectId: project.id)
        let launch = try #require(world.processes.launches.last)
        #expect(launch.executable == "/bin/zsh")
        #expect(launch.args == ["-l", "-i", "-c", "npm run dev -- --port 3000"])
        #expect(launch.directory == repo.path)
        let run = try #require(store.commandRuns.first)
        #expect(run.running && run.branchName == "main")
        #expect(store.dockExpanded && store.dockRunId == run.id)
        #expect(store.runningCommandsCount == 1)

        // Correrlo de nuevo en la misma rama no duplica: muestra el que ya corre.
        store.dockExpanded = false
        store.run(command.id, projectId: project.id)
        #expect(store.commandRuns.count == 1 && store.dockExpanded)

        store.commandExited(run.id, terminal: try #require(run.terminal), code: 0)
        #expect(!run.running && run.exitCode == 0)
        store.closeRun(run.id)
        #expect(store.commandRuns.isEmpty && !store.dockExpanded)

        store.deleteCommand(projectId: project.id, commandId: command.id)
        #expect(store.project(project.id)?.commands.isEmpty == true)
    }

    @Test("Un script suelto corre con su entorno, se ve en la esquinita y se puede reiniciar")
    func runScript() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        let id = try #require(store.runScript(name: "Preparar main", command: "composer install", projectId: project.id,
                                              branchId: project.branches[0].id, environment: ["HIVE_BRANCH": "main", "PATH": "/otro"]))
        let launch = try #require(world.processes.launches.last)
        #expect(launch.args == ["-l", "-i", "-c", "composer install"])
        #expect(launch.directory == repo.path)
        #expect(launch.environment["HIVE_BRANCH"] == "main")
        #expect(launch.environment["PATH"] == "/otro") // lo del script gana
        let run = try #require(store.commandRuns.first { $0.id == id })
        #expect(run.isScript && run.running && run.name == "Preparar main")
        #expect(store.dockExpanded && store.dockRunId == id)
        #expect(project.commands.isEmpty)
        store.restartRun(id)
        #expect(world.processes.launches.count == 2)
        #expect(world.processes.launches.last?.environment["HIVE_BRANCH"] == "main")
        #expect(store.runScript(name: "x", command: "y", projectId: project.id, branchId: UUID()) == nil)
    }

    @Test("Los comandos corren en la rama abierta del proyecto")
    func commandBranch() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        _ = await store.createBranch(NewBranchRequest(projectId: project.id, name: "wt", isNew: true, mode: .worktree))
        let worktree = try #require(store.project(project.id)?.branches.last)
        store.select(.branch(worktree.id))
        #expect(store.defaultBranch(for: try #require(store.project(project.id)))?.id == worktree.id)
        store.select(nil)
        #expect(store.defaultBranch(for: try #require(store.project(project.id)))?.name == "main")
        store.saveCommand(projectId: project.id, commandId: nil, name: "Test", command: "make test")
        let command = try #require(store.project(project.id)?.commands.first)
        store.run(command.id, projectId: project.id, branchId: worktree.id)
        #expect(world.processes.launches.last?.directory == worktree.worktreePath)

        // Terminó, y el worktree se movió por fuera (git worktree move): correrlo de nuevo reutiliza la
        // pestaña, pero en la carpeta nueva.
        let run = try #require(store.commandRuns.first)
        store.commandExited(run.id, terminal: try #require(run.terminal), code: 0)
        let moved = repo.dir.url.path + "/wt-movido"
        repo.sh("git worktree move \(shellQuote(try #require(worktree.worktreePath))) \(shellQuote(moved))")
        await store.refreshGitNow()
        #expect(store.project(project.id)?.branches.last?.worktreePath == moved)
        store.run(command.id, projectId: project.id, branchId: worktree.id)
        #expect(store.commandRuns.count == 1)
        #expect(world.processes.launches.last?.directory == moved)
        #expect(run.directory == moved)
    }

    @Test("MCP: guardar y quitar actualiza el .mcp.json")
    func mcp() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        let version = store.mcpVersion
        store.saveMCP(MCPServer(name: "boost", config: ["command": "php"]), replacing: nil, projectId: project.id)
        #expect(MCPConfig.load(dir: repo.path).map(\.name) == ["boost"])
        #expect(store.mcpVersion == version + 1)
        store.removeMCP("boost", projectId: project.id)
        #expect(MCPConfig.load(dir: repo.path).isEmpty)
        #expect(store.mcpSuggestions(for: project, existing: []).map(\.name).last == "context7")
        #expect(store.mcpGlobals(for: project).isEmpty)
    }

    @Test("El diff abre en el archivo tocado, con preparados primero")
    func diffTarget() {
        let status = GitStatus(changes: [GitChange(code: " M", path: "a"), GitChange(code: "M ", path: "b"), GitChange(code: "MM", path: "c")])
        let target = DiffTarget.make(directory: "/r", status: status, change: GitChange(code: "MM", path: "c"), staged: false)
        #expect(target.files.map { "\($0.change.path)\($0.staged ? "+" : "")" } == ["b+", "c+", "a", "c"])
        #expect(target.selected == 3)
        let missing = DiffTarget.make(directory: "/r", status: status, change: GitChange(code: "??", path: "z"), staged: false)
        #expect(missing.selected == 0)
    }

    @Test("Aviso al salir")
    func quitWarning() {
        #expect(QuitWarning.message(working: 0, commands: 0) == nil)
        #expect(QuitWarning.message(working: 1, commands: 0) == "Hay una sesión trabajando")
        #expect(QuitWarning.message(working: 2, commands: 1) == "Hay 2 sesiones trabajando y un comando corriendo")
        #expect(QuitWarning.message(working: 0, commands: 3) == "Hay 3 comandos corriendo")
    }

    @Test("Ajustes por defecto y leídos de UserDefaults")
    func settings() async throws {
        // Un dominio propio en una carpeta temporal (nunca UserDefaults.standard), que se borra al terminar.
        let preferences = SnapshotDefaults()
        let defaults = preferences.defaults
        #expect(AppSettings.read(defaults) == AppSettings(claudeInline: true, historyHint: true, showClaudeUsage: true))
        defaults.set(false, forKey: AppSettings.claudeInlineKey)
        #expect(AppSettings.read(defaults).claudeInline == false)
        defaults.set(false, forKey: AppSettings.showClaudeUsageKey)
        #expect(AppSettings.read(defaults).showClaudeUsage == false)
    }
}
