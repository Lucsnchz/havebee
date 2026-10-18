import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// La sesión arrancó en main y el agente se fue a trabajar a otra rama: Hive lo muestra con lo que
/// informa cada evento (su carpeta) y con la rama de la carpeta principal.
@MainActor
@Suite("Store: la rama donde trabaja el agente")
struct StoreAgentDriftTests {
    typealias Setup = AppStoreSessionTests.Setup

    func bash(_ id: UUID, cwd: String) -> HiveEvent {
        HiveEvent(sessionId: id, source: "claude", name: "PostToolUse", payload: ["tool_name": "Bash", "cwd": .string(cwd)])
    }

    @Test("Se pasa a otro worktree: muestra esa rama y sus cambios hasta que vuelve o se relanza")
    func otherWorktree() async throws {
        let s = try await Setup()
        let error = await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "mensajes", isNew: true,
                                                                base: "main", mode: .worktree))
        #expect(error == nil)
        let worktree = try #require(s.store.project(s.project.id)?.branches.last?.worktreePath)
        try "hola".write(toFile: worktree + "/nuevo.txt", atomically: true, encoding: .utf8)
        let session = try s.newSession(.claude)
        s.store.activate(session.id)
        await s.store.refreshGitNow()
        let rt = try #require(s.store.runtimes[session.id])
        #expect(s.store.agentDrift(session.id) == nil)

        s.store.handle([bash(session.id, cwd: worktree + "/app")])
        let drift = try #require(s.store.agentDrift(session.id))
        #expect(drift == AgentDrift(branchName: "mensajes", directory: worktree))
        #expect(s.store.gitStatus(for: drift)?.branch == "mensajes")
        #expect(s.store.gitStatus(for: drift)?.changes.map(\.path) == ["nuevo.txt"])

        // Vuelve a su carpeta.
        s.store.handle([bash(session.id, cwd: s.repo.path)])
        #expect(s.store.agentDrift(session.id) == nil)

        // Relanzada, arranca de nuevo en la carpeta de su rama.
        s.store.handle([bash(session.id, cwd: worktree)])
        #expect(s.store.agentDrift(session.id) != nil)
        s.store.relaunch(session.id)
        #expect(rt.workingDirectory == nil)
        #expect(s.store.agentDrift(session.id) == nil)
    }

    @Test("La pestaña, la barra de abajo y Cambios lo muestran (HIVE_SNAPSHOTS guarda las capturas)")
    func rendered() async throws {
        let s = try await Setup()
        _ = await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "mensajes-wsp", isNew: true,
                                                        base: "main", mode: .worktree))
        let worktree = try #require(s.store.project(s.project.id)?.branches.last?.worktreePath)
        try "hola".write(toFile: worktree + "/nuevo.txt", atomically: true, encoding: .utf8)
        let session = try s.newSession(.claude)
        s.store.activate(session.id)
        s.store.handle([bash(session.id, cwd: worktree)])
        await s.store.refreshGitNow()
        let defaults = try #require(UserDefaults(suiteName: "deriva-\(UUID().uuidString)"))
        defaults.set("changes", forKey: "sessionSidePanel")
        let reps = await Snapshot.render(CompactLayout().environment(s.store), size: CGSize(width: 1100, height: 380),
                                         name: "deriva-compacta", defaults: defaults)
        #expect(reps.count == 2)
        #expect(reps.allSatisfy { Snapshot.distinctColors($0) > 8 })
    }

    @Test("Checkout de otra rama en la carpeta principal: la sesión de main muestra la nueva; dormida, nada")
    func checkoutInMainFolder() async throws {
        let s = try await Setup()
        let session = try s.newSession(.claude)
        let dormant = try s.newSession(.claude)
        s.store.activate(session.id)
        await s.store.refreshGitNow()
        #expect(s.store.agentDrift(session.id) == nil)

        s.repo.sh("git checkout -q -b arreglo-pagos")
        await s.store.refreshGitNow()
        #expect(s.store.agentDrift(session.id) == AgentDrift(branchName: "arreglo-pagos", directory: s.project.path))
        #expect(s.store.agentDrift(dormant.id) == nil)
    }
}
