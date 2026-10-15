import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: agregar proyectos y worktrees faltantes")
struct StoreProjectsTests {
    @Test("Un worktree borrado por fuera avisa una sola vez y queda en missingWorktrees")
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

        try FileManager.default.removeItem(atPath: path)
        await store.refreshGitNow()
        #expect(store.missingWorktrees.contains(path))
        #expect(store.isMissing(branch))
        #expect(!store.isMissing(project.branches[0]))

        // Mirar la sesión varias veces avisa una sola vez.
        store.activate(session.id)
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
        store.activate(session.id)
        #expect(world.processes.launches.count == 1)
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
