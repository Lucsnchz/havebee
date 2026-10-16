import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: deshacer")
struct StoreUndoTests {
    /// Un store con un repo agregado (el mundo queda vivo mientras dure el test).
    @MainActor
    private final class Setup {
        let world = TestWorld()
        let repo = GitRepo()
        let store: AppStore
        let project: Project

        init() async throws {
            store = world.makeStore()
            await store.addProject(at: repo.path)
            project = try #require(store.repoProjects.first)
        }
    }

    @Test("Deshacer archivar la restaura y la vuelve a abrir si era la abierta")
    func undoArchive() async throws {
        let s = try await Setup()
        let (store, project) = (s.store, s.project)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        store.requestNewSession(branchId: project.branches[0].id, kind: .codex)
        let sessions = try #require(store.project(project.id)?.branches[0].sessions)
        let (claude, codex) = (sessions[0], sessions[1])

        store.select(.session(claude.id))
        store.archive(claude.id)
        #expect(store.undoAction?.message == "Archivaste «Claude 1»")
        #expect(store.selection == .session(codex.id))
        store.performUndo()
        #expect(store.sessionContext(claude.id)?.session.isArchived == false)
        #expect(store.selection == .session(claude.id))
        #expect(store.undoAction == nil)
        store.performUndo() // ya no hay nada para deshacer
        #expect(store.sessionContext(claude.id)?.session.isArchived == false)

        // Si no era la abierta, se restaura sin cambiar lo que estás mirando.
        store.archive(codex.id)
        #expect(store.selection == .session(claude.id))
        store.performUndo()
        #expect(store.sessionContext(codex.id)?.session.isArchived == false)
        #expect(store.selection == .session(claude.id))
    }

    @Test("Eliminar una sesión ya archivada no ofrece archivarla; archivarla de nuevo no hace nada")
    func deleteArchived() async throws {
        let s = try await Setup()
        let (store, project) = (s.store, s.project)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        store.requestNewSession(branchId: project.branches[0].id, kind: .shell)
        let sessions = try #require(store.project(project.id)?.branches[0].sessions)
        let (claude, shell) = (sessions[0], sessions[1])

        // Abierta: se puede archivar en lugar de eliminarla.
        store.requestRemoval(.session(claude.id))
        #expect(store.pendingRemoval?.offersArchive == true)

        store.archive(claude.id)
        store.archive(shell.id)
        store.dismissUndo()
        let archivedAt = try #require(store.sessionContext(claude.id)?.session.archivedAt)
        store.requestRemoval(.session(claude.id))
        #expect(store.pendingRemoval?.offersArchive == false)
        #expect(store.pendingRemoval?.message == "También se borra su historial en Hive (todo lo anterior a cada /clear). No se puede deshacer.")
        store.requestRemoval(.session(shell.id))
        #expect(store.pendingRemoval?.offersArchive == false)
        #expect(store.pendingRemoval?.message == "Se borra de las archivadas. No se puede deshacer.")

        // Archivar otra vez una archivada no le cambia la fecha ni ofrece un deshacer que la restauraría.
        s.world.advance(60)
        store.archive(claude.id)
        #expect(store.sessionContext(claude.id)?.session.archivedAt == archivedAt)
        #expect(store.undoAction == nil)
    }

    @Test("⌘Z (el undo de la ventana) restaura lo archivado; deshacer con la cápsula lo saca del menú")
    func commandZ() async throws {
        let s = try await Setup()
        let (store, project) = (s.store, s.project)
        let manager = UndoManager()
        manager.groupsByEvent = false // en la app, cada clic es un grupo; acá lo armamos a mano
        store.windowUndoManager = { manager }
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.branches[0].sessions.first)
        func archive() {
            manager.beginUndoGrouping()
            store.archive(session.id)
            manager.endUndoGrouping()
        }

        archive()
        #expect(manager.undoActionName == "Archivaste «Claude 1»")
        manager.undo()
        #expect(store.sessionContext(session.id)?.session.isArchived == false)
        #expect(store.selection == .session(session.id))
        #expect(store.undoAction == nil) // la cápsula se va
        #expect(!manager.canUndo)

        archive()
        #expect(manager.canUndo)
        store.performUndo()
        #expect(store.sessionContext(session.id)?.session.isArchived == false)
        #expect(!manager.canUndo) // ⌘Z ya no ofrece algo que no haría nada
    }

    @Test("Deshacer quitar un MCP lo vuelve a agregar igual que estaba")
    func undoRemoveMCP() async throws {
        let s = try await Setup()
        let (repo, store, project) = (s.repo, s.store, s.project)
        let server = MCPServer(name: "boost", config: ["command": "php", "args": ["artisan", "boost:mcp"], "env": ["APP_ENV": "local"]])
        store.saveMCP(server, replacing: nil, projectId: project.id)
        store.saveMCP(MCPServer(name: "otro", config: ["url": "https://example.com/mcp"]), replacing: nil, projectId: project.id)
        store.removeMCP("boost", projectId: project.id)
        #expect(MCPConfig.load(dir: repo.path).map(\.name) == ["otro"])
        #expect(store.undoAction?.message == "Quitaste el MCP «boost»")
        let version = store.mcpVersion
        store.performUndo()
        #expect(MCPConfig.load(dir: repo.path).map(\.name) == ["boost", "otro"])
        #expect(MCPConfig.load(dir: repo.path).first == server)
        #expect(store.mcpVersion == version + 1)
    }

    @Test("Deshacer borrar un comando lo devuelve al mismo lugar")
    func undoDeleteCommand() async throws {
        let s = try await Setup()
        let (world, store, project) = (s.world, s.store, s.project)
        for (name, command) in [("Dev", "npm run dev"), ("Test", "npm test"), ("Cola", "php artisan queue:work")] {
            store.saveCommand(projectId: project.id, commandId: nil, name: name, command: command)
        }
        let middle = try #require(store.project(project.id)?.commands[1])
        store.deleteCommand(projectId: project.id, commandId: middle.id)
        #expect(store.project(project.id)?.commands.map(\.name) == ["Dev", "Cola"])
        #expect(store.undoAction?.message == "Borraste el comando «Test»")
        store.performUndo()
        #expect(store.project(project.id)?.commands.map(\.name) == ["Dev", "Test", "Cola"])
        #expect(store.project(project.id)?.commands[1] == middle)
        // Y quedó guardado.
        #expect(world.makeStore().project(project.id)?.commands.map(\.name) == ["Dev", "Test", "Cola"])
    }

    @Test("Una acción nueva reemplaza la anterior y la cápsula se puede cerrar")
    func latestWins() async throws {
        let s = try await Setup()
        let (store, project) = (s.store, s.project)
        store.saveCommand(projectId: project.id, commandId: nil, name: "A", command: "a")
        store.saveCommand(projectId: project.id, commandId: nil, name: "B", command: "b")
        let commands = try #require(store.project(project.id)?.commands)
        store.deleteCommand(projectId: project.id, commandId: commands[0].id)
        store.deleteCommand(projectId: project.id, commandId: commands[1].id)
        #expect(store.undoAction?.message == "Borraste el comando «B»")
        let expires = try #require(store.undoAction?.expiresAt)
        #expect(abs(expires.timeIntervalSince(Date.reference) - AppStore.undoWindow) < 0.001)
        store.dismissUndo()
        #expect(store.undoAction == nil)
        store.performUndo()
        #expect(store.project(project.id)?.commands.isEmpty == true)
    }
}
