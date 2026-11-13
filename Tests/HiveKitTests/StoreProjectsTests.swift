import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: agregar proyectos y worktrees faltantes")
struct StoreProjectsTests {
    @Test("Un worktree borrado por fuera avisa una sola vez mientras la revisión de git no lo saca")
    func missingWorktree() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.createBranch(NewBranchRequest(projectId: project.id, name: "borrada", isNew: true, mode: .worktree,
                                                          firstSession: .claude)) == nil)
        let branch = try #require(store.project(project.id)?.branches.last)
        let path = try #require(branch.worktreePath)
        let session = try #require(branch.sessions.first)
        store.saveCommand(projectId: project.id, commandId: nil, name: "Test", command: "make test")
        let command = try #require(store.project(project.id)?.commands.first)

        // La próxima revisión de git saca la rama de Hive (no tiene nada corriendo); hasta entonces,
        // abrir lo que hay adentro avisa que la carpeta no está.
        try FileManager.default.removeItem(atPath: path)

        // Mirar la sesión varias veces avisa una sola vez y marca la carpeta como faltante.
        store.activate(session.id)
        #expect(store.missingWorktrees.contains(path))
        #expect(store.isMissing(branch))
        #expect(!store.isMissing(project.branches[0]))
        #expect(store.alerts.count == 1)
        #expect(store.alert?.title == "No encuentro la carpeta de «borrada»")
        #expect(store.alert?.message.hasPrefix(path) == true)
        store.alert = nil
        store.activate(session.id)
        store.activate(session.id)
        #expect(store.alert == nil)
        #expect(world.processes.launches.isEmpty)

        // Lo mismo con un comando.
        store.run(command.id, projectId: project.id, branchId: branch.id)
        store.run(command.id, projectId: project.id, branchId: branch.id)
        #expect(store.alerts.count == 1)
        #expect(store.commandRuns.isEmpty)

        // Si la carpeta vuelve, deja de figurar como faltante y se puede lanzar.
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        await store.refreshGitNow()
        #expect(!store.isMissing(branch))
        #expect(store.project(project.id)?.branches.contains { $0.id == branch.id } == true)
        store.activate(session.id)
        #expect(world.processes.launches.count == 1)
    }

    @Test("Si falta la carpeta principal, el aviso habla del proyecto, no de la rama")
    func missingMainFolder() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .shell)
        let session = try #require(store.project(project.id)?.allSessions.first)
        try FileManager.default.moveItem(atPath: repo.path, toPath: repo.path + "-movido")
        store.activate(session.id)
        #expect(store.alert?.title == "No encuentro la carpeta de «repo»")
        #expect(store.alert?.message.hasSuffix("Si ya no lo usás, quitá el proyecto de Havebee.") == true)
        #expect(!store.isMissing(project.branches[0]))
        #expect(world.processes.launches.isEmpty)
    }

    @Test("La carpeta de un worktree agrega o selecciona el repo principal, sin duplicarlo")
    func worktreeFolderAddsMainRepo() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let worktree = repo.dir.url.path + "/arreglo"
        repo.sh("git worktree add -q -b arreglo \(shellQuote(worktree))")
        let store = world.makeStore()

        await store.addProject(at: worktree)
        #expect(store.repoProjects.count == 1)
        let project = try #require(store.repoProjects.first)
        #expect(project.path == repo.path && project.name == "repo")
        #expect(project.branches.map(\.name) == ["main", "arreglo"])
        let branch = try #require(project.branches.last)
        #expect(store.selection == .branch(branch.id))
        #expect(store.mainHead(of: project.id) == "main")

        await store.addProject(at: repo.path)
        #expect(store.repoProjects.count == 1)
        #expect(store.selection == .project(project.id))

        // Si habías quitado ese worktree de Hive, elegirlo de nuevo lo vuelve a sumar.
        #expect(await store.performRemove(.branch(branch.id)))
        #expect(store.project(project.id)?.branches.map(\.name) == ["main"])
        await store.addProject(at: worktree + "/")
        #expect(store.repoProjects.count == 1)
        let again = try #require(store.project(project.id)?.branches.last)
        #expect(again.name == "arreglo")
        #expect(store.selection == .branch(again.id))
        #expect(store.project(project.id)?.ignoredWorktrees.isEmpty == true)
    }

    @Test("Con HEAD desacoplado no se crea una rama «HEAD»")
    func detachedHead() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = GitRepo()
        repo.sh("git checkout -q --detach")
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(project.branches.map(\.name) == ["main"])
        #expect(store.mainHead(of: project.id) == "")
        #expect(!store.isActive(project.branches[0], in: project))

        // Sin origin/HEAD, main ni master, el proyecto queda sin ramas.
        let other = GitRepo(branch: "trunk", name: "otro")
        other.sh("git checkout -q --detach")
        await store.addProject(at: other.path)
        let bare = try #require(store.repoProjects.first { $0.name == "otro" })
        #expect(bare.branches.isEmpty)
        #expect(store.selection == .project(bare.id))
    }

    @Test("Varias carpetas a la vez: se agregan todas y queda abierta la última")
    func severalFolders() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let a = GitRepo(name: "uno"), b = GitRepo(name: "dos")
        let notRepo = TempDir()
        await store.addProjects([a.path, notRepo.path, b.path])
        #expect(store.repoProjects.map(\.name) == ["uno", "dos"])
        let last = try #require(store.repoProjects.last)
        #expect(store.selection == .branch(last.branches[0].id))
        #expect(store.alert?.title == "No es un repositorio git")
    }
}

@MainActor
@Suite("Store: la carpeta principal cambió de rama por fuera")
struct StoreMovedHeadTests {
    @MainActor
    private final class Setup {
        let world = TestWorld()
        let repo = GitRepo()
        let store: AppStore
        let project: Project
        var session: Session!

        init() async throws {
            store = world.makeStore()
            await store.addProject(at: repo.path)
            project = try #require(store.repoProjects.first)
        }

        func runSession(on branchId: UUID) throws {
            store.requestNewSession(branchId: branchId, kind: .claude)
            session = try #require(store.branchContext(branchId)?.branch.sessions.last)
            store.activate(session.id)
        }
    }

    @Test("Si no hay una rama con ese nombre, «Mover las sesiones ahí» renombra la rama")
    func renamesBranch() async throws {
        let s = try await Setup()
        let main = s.project.branches[0]
        try s.runSession(on: main.id)
        s.repo.sh("git checkout -q -b fix/bar")
        await s.store.refreshGitNow()
        let alert = try #require(s.store.alert)
        #expect(alert.title == "Algo cambió la carpeta principal de «main» a «fix/bar»")
        #expect(alert.message == "La sesión «Claude 1» quedó viendo «fix/bar» en «repo». ¿La movés a esa rama en Havebee?")
        #expect(alert.actionTitle == "Mover las sesiones ahí" && alert.cancelTitle == "Dejar así")
        #expect(!alert.isDestructive)
        alert.action?()
        let renamed = try #require(s.store.branchContext(main.id))
        #expect(renamed.branch.name == "fix/bar")
        #expect(renamed.branch.sessions.map(\.id) == [s.session.id])
        #expect(s.store.isActive(renamed.branch, in: renamed.project))
        await s.store.refreshGitNow()
        #expect(s.store.alerts.count == 1) // no vuelve a preguntar
    }

    @Test("Con varias sesiones corriendo, la pregunta va en plural")
    func pluralQuestion() async throws {
        let s = try await Setup()
        let main = s.project.branches[0]
        try s.runSession(on: main.id)
        try s.runSession(on: main.id)
        s.repo.sh("git checkout -q -b fix/bar")
        await s.store.refreshGitNow()
        #expect(s.store.alert?.message == "Las 2 sesiones de esa rama quedaron viendo «fix/bar» en «repo». ¿Las movés a esa rama en Havebee?")
    }

    @Test("Si ya hay una rama con ese nombre, le pasa las sesiones que corrían")
    func movesToExistingBranch() async throws {
        let s = try await Setup()
        #expect(await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "otra", isNew: true, mode: .main)) == nil)
        let main = s.project.branches[0]
        s.store.requestNewSession(branchId: main.id, kind: .shell) // dormida: se queda donde está
        let dormant = try #require(s.store.branchContext(main.id)?.branch.sessions.last)
        try s.runSession(on: main.id)
        s.repo.sh("git checkout -q otra")
        await s.store.refreshGitNow()
        let alert = try #require(s.store.alert)
        #expect(alert.title == "Algo cambió la carpeta principal de «main» a «otra»")
        alert.action?()
        let otra = try #require(s.store.project(s.project.id)?.branches.first { $0.name == "otra" })
        #expect(otra.sessions.map(\.id) == [s.session.id])
        #expect(s.store.branchContext(main.id)?.branch.sessions.map(\.id) == [dormant.id])
        #expect(s.store.branchContext(main.id)?.branch.name == "main")
    }

    @Test("Sin sesiones corriendo, o con un checkout de Hive, no pregunta nada")
    func noQuestion() async throws {
        let s = try await Setup()
        s.repo.sh("git checkout -q -b afuera")
        await s.store.refreshGitNow()
        #expect(s.store.alert == nil)
        #expect(s.store.mainHead(of: s.project.id) == "afuera")

        s.repo.sh("git checkout -q main")
        await s.store.refreshGitNow()
        #expect(s.store.alert == nil)
        #expect(await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "de-hive", isNew: true, mode: .main)) == nil)
        try s.runSession(on: s.project.branches[0].id)
        let deHive = try #require(s.store.project(s.project.id)?.branches.first { $0.name == "de-hive" })
        s.store.requestCheckout(branchId: deHive.id)
        #expect(await s.store.performCheckout(try #require(s.store.pendingCheckout)))
        await s.store.refreshGitNow()
        #expect(s.store.alert == nil)
    }
}
