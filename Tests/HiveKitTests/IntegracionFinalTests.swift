import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Lo que se terminó de cablear después de juntar todos los paquetes (I6 a I9 y pendientes).
@MainActor
@Suite("Integración final", .serialized)
struct IntegracionFinalTests {
    /// Dibuja en oscuro y en claro y devuelve cuántos colores distintos tiene cada captura.
    private func colors(_ view: some View, size: CGSize, name: String) async -> [Int] {
        let defaults = SnapshotDefaults()
        let reps = await Snapshot.render(view, size: size, name: name, defaults: defaults.defaults)
        #expect(reps.count == 2, "No se pudo dibujar \(name)")
        return reps.map(Snapshot.distinctColors)
    }

    @Test("I7: en el Resumen, Comandos y MCP no repiten el «Agregar» del título")
    func singleAddButtons() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        defer { withExtendedLifetime(repo) {} }
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        // Sin comandos ni sugerencias (el repo no tiene package.json): sin su botón, la lista no dibuja nada.
        let hidden = await colors(CommandsSection(project: project, showsAddButton: false).environment(store),
                                  size: CGSize(width: 520, height: 60), name: "i7-comandos-sin-agregar")
        #expect(hidden.allSatisfy { $0 == 1 }, "Sin «Agregar comando» no debería verse nada: \(hidden)")
        let shown = await colors(CommandsSection(project: project).environment(store),
                                 size: CGSize(width: 520, height: 60), name: "i7-comandos-con-agregar")
        #expect(shown.allSatisfy { $0 > 1 })

        // Con un comando y un MCP, el Resumen entero se dibuja con las filas como tarjetas.
        repo.write(".mcp.json", #"{"mcpServers": {"docs": {"command": "npx", "args": ["docs-mcp"]}}}"#)
        store.saveCommand(projectId: project.id, commandId: nil, name: "Servidor", command: "php artisan serve")
        let summary = await colors(NavigationStack { ProjectDetailView(projectId: project.id) }.environment(store),
                                   size: CGSize(width: 900, height: 760), name: "i7-resumen")
        #expect(summary.allSatisfy { $0 > 3 })
    }

    /// Un repo con una sesión de Claude que ya habló (el historial queda guardado).
    private func storeWithHistory() async throws -> (TestWorld, GitRepo, AppStore, Project, Session) {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.branches[0].sessions.first)
        store.activate(session.id)
        store.handle([
            HiveEvent(sessionId: session.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Corré la migración de pedidos"]),
            HiveEvent(sessionId: session.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "Listo, la migración pasó sin errores."]),
        ])
        store.select(nil)
        store.setExpanded(project.id, false)
        return (world, repo, store, project, session)
    }

    @Test("I9: «?» en ⌘K encuentra lo que hablaste y abre la sesión en esa entrada")
    func historyFromSwitcher() async throws {
        let (world, repo, store, project, session) = try await storeWithHistory()
        defer { withExtendedLifetime((world, repo)) {} }
        let query = try #require(SwitcherIndex.historyQuery("?migracion"))
        let hits = store.history.search(query, sessionIds: SwitcherIndex.historySessionIds(store.projects), limit: QuickSwitcher.historyLimit)
        let items = SwitcherIndex.historyItems(hits, query: query, in: store.projects)
        #expect(items.count == 2)
        let hit = try #require(hits.first)

        // Abrir: selecciona la sesión, despliega el árbol, pasa el panel a «Historial» y pide el salto.
        let jumps = HistoryJumpRequest()
        let defaults = SnapshotDefaults()
        #expect(HiveNavigator.openHistoryEntry(store, session: session.id, entry: hit.entryId, query: query,
                                               jumps: jumps, defaults: defaults.defaults))
        #expect(store.selection == .session(session.id))
        #expect(store.isExpanded(project.id))
        #expect(defaults.defaults.string(forKey: "sessionSidePanel") == "history")
        #expect(jumps.pending == .init(sessionId: session.id, entryId: hit.entryId, query: query))

        // Una archivada no se abre: queda pedido el salto y el buscador muestra su historial.
        store.archive(session.id)
        store.select(nil)
        let archivedJumps = HistoryJumpRequest()
        #expect(!HiveNavigator.openHistoryEntry(store, session: session.id, entry: hit.entryId, query: query,
                                                jumps: archivedJumps, defaults: defaults.defaults))
        #expect(store.selection == nil)
        #expect(archivedJumps.pending?.entryId == hit.entryId)
    }

    @Test("I9: el buscador con «?» dibuja los mensajes encontrados y la ayuda")
    func historySwitcherRender() async throws {
        let (world, repo, store, _, _) = try await storeWithHistory()
        defer { withExtendedLifetime((world, repo)) {} }
        let found = await colors(QuickSwitcher(query: "?migración").environment(store), size: CGSize(width: 600, height: 520),
                                 name: "i9-buscador-historial")
        #expect(found.allSatisfy { $0 > 3 })
        let hint = await colors(QuickSwitcher(query: "?").environment(store), size: CGSize(width: 600, height: 260),
                                name: "i9-buscador-historial-ayuda")
        #expect(hint.allSatisfy { $0 > 3 })
    }
}
