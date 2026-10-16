import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: deshacer quitar un proyecto")
struct StoreRemoveProjectUndoTests {
    @Test("Deshacer devuelve el proyecto en su lugar, con sesiones (dormidas), archivadas, comandos y color")
    func undoRestoresEverything() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let first = GitRepo(name: "bevo")
        let second = GitRepo(name: "tienda")
        await store.addProject(at: first.path)
        await store.addProject(at: second.path)
        let project = try #require(store.repoProjects.first { $0.name == "bevo" })
        let index = try #require(store.projects.firstIndex { $0.id == project.id })
        let branch = project.branches[0].id
        store.requestNewSession(branchId: branch, kind: .claude)
        store.requestNewSession(branchId: branch, kind: .shell)
        let sessions = try #require(store.project(project.id)?.branches[0].sessions)
        store.archive(sessions[1].id)
        store.saveCommand(projectId: project.id, commandId: nil, name: "Dev", command: "npm run dev")
        store.setColor(.teal, project: project.id)
        store.select(.session(sessions[0].id))
        store.activate(sessions[0].id)
        let before = try #require(store.project(project.id))

        #expect(await store.performRemove(.project(project.id)))
        #expect(store.project(project.id) == nil)
        #expect(store.runtimes[sessions[0].id] == nil)
        #expect(store.selection == nil)
        #expect(store.undoAction?.message == "Quitaste «bevo» de Hive")

        store.performUndo()
        let restored = try #require(store.project(project.id))
        #expect(restored == before)
        #expect(store.projects.firstIndex { $0.id == project.id } == index)
        #expect(restored.commands.map(\.name) == ["Dev"])
        #expect(restored.branches[0].archivedSessions.map(\.id) == [sessions[1].id])
        // Las sesiones vuelven dormidas (no se relanzan solas) y se abre el proyecto, no la sesión.
        #expect(store.runtimes[sessions[0].id]?.status == .dormant)
        #expect(store.runtimes[sessions[0].id]?.isRunning == false)
        #expect(store.runtimes[sessions[1].id] != nil)
        #expect(store.selection == .project(project.id))
        #expect(store.undoAction == nil)
    }

    @Test("Si mientras tanto lo volviste a agregar, deshacer no lo duplica")
    func undoAfterReAdding() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = GitRepo(name: "bevo")
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.performRemove(.project(project.id)))
        let undo = try #require(store.undoAction)
        await store.addProject(at: repo.path)
        #expect(store.repoProjects.count == 1)
        store.undoAction = undo
        store.performUndo()
        #expect(store.repoProjects.count == 1)
        #expect(store.repoProjects.first?.id != project.id)
    }
}
