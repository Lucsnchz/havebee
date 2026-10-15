import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Arreglos que aparecieron al juntar los paquetes.
@Suite("Integración")
struct IntegracionTests {
    @Test("Los commits recientes se vuelven a leer cuando cambia HEAD, aunque no haya upstream")
    func recentCommitsRefreshKeyUsesHeadOid() {
        var status = GitStatus(branch: "main", headOid: "aaa111")
        let before = RecentCommits.refreshKey(status)
        status.headOid = "bbb222"
        #expect(RecentCommits.refreshKey(status) != before)
        // Sin oid (repo sin commits) se sigue usando la clave anterior.
        status.headOid = nil
        #expect(RecentCommits.refreshKey(status) == "main|0|0|0")
        #expect(RecentCommits.refreshKey(nil) == "-")
    }
}

/// Las piezas que cablea la integración, dibujadas de verdad (con `HIVE_SNAPSHOTS` quedan en PNG).
@MainActor
@Suite("Integración: vistas", .serialized)
struct IntegracionViewTests {
    /// Un repo con una sesión de Claude lanzada (con procesos falsos).
    private func storeWithClaude() async throws -> (TestWorld, GitRepo, AppStore, Project, Session) {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.branches[0].sessions.first)
        store.activate(session.id)
        #expect(await waitUntil { store.runtimes[session.id]?.terminal != nil })
        store.select(nil)
        return (world, repo, store, project, session)
    }

    private func check(_ view: some View, size: CGSize, name: String) async {
        let defaults = SnapshotDefaults()
        let reps = await Snapshot.render(view, size: size, name: name, defaults: defaults.defaults)
        #expect(reps.count == 2, "No se pudo dibujar \(name)")
        for rep in reps { #expect(Snapshot.distinctColors(rep) > 3, "\(name) parece vacía") }
    }

    @Test("La tarjeta de una sesión que pide permiso muestra el pedido")
    func attentionCard() async throws {
        let (world, repo, store, project, session) = try await storeWithClaude()
        defer { withExtendedLifetime((world, repo)) {} }
        store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "PermissionRequest",
                                payload: ["tool_name": "Bash", "tool_input": ["command": "php artisan migrate"]])])
        #expect(store.runtimes[session.id]?.notice != nil)
        await check(NavigationStack { BranchDetailView(branchId: project.branches[0].id) }.environment(store),
                    size: CGSize(width: 1000, height: 640), name: "19-rama-permiso")
    }
}
