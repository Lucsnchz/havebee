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
}
