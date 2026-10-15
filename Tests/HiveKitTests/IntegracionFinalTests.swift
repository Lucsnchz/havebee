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
}
