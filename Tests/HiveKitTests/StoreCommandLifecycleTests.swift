import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Un store que corre los comandos de verdad (con /bin/sh) en un repo de prueba.
@MainActor
private final class CommandWorld {
    let world = TestWorld()
    let repo = GitRepo()
    let store: AppStore

    init() async {
        _ = NSApplication.shared
        var real = world.environment
        real.processes = TerminalProcessStarter()
        real.loginShell = "/bin/sh"
        store = AppStore(environment: real)
        await store.addProject(at: repo.path)
    }

    var project: Project { store.repoProjects[0] }

    /// Guarda un comando y lo corre en una rama (la abierta si no se dice cuál).
    @discardableResult
    func run(_ command: String, branchId: UUID? = nil) throws -> CommandRun {
        store.saveCommand(projectId: project.id, commandId: nil, name: command, command: command)
        let saved = try #require(store.project(project.id)?.commands.last)
        store.run(saved.id, projectId: project.id, branchId: branchId)
        return try #require(store.commandRuns.last)
    }

    /// Espera a que el proceso arranque de verdad (antes, un Ctrl+C se pierde).
    func started(_ run: CommandRun) async -> Bool {
        await waitUntil { run.terminal?.isProcessRunning == true }
    }
}

@MainActor
@Suite("Store: comandos con procesos reales", .serialized)
struct StoreCommandLifecycleTests {
    @Test("Detener y reiniciar enseguida: el comando nuevo sigue vivo después del plazo de gracia")
    func stopThenRestart() async throws {
        let w = await CommandWorld()
        let run = try w.run("exec sleep 30")
        #expect(await w.started(run))
        let old = try #require(run.terminal)
        w.store.stopRun(run.id)
        w.store.restartRun(run.id)
        let fresh = try #require(run.terminal)
        #expect(fresh !== old)
        #expect(await w.started(run))
        // Pasa el plazo de gracia (0,2 s en los tests) y un poco más.
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(run.terminal === fresh)
        #expect(run.running)
        #expect(fresh.isProcessRunning)
        #expect(await waitUntil { !old.isProcessRunning })
        w.store.closeRun(run.id)
        #expect(await waitUntil { !fresh.isProcessRunning })
    }

    @Test("Si ignora Ctrl+C, se corta al vencer el plazo de gracia")
    func ignoresInterrupt() async throws {
        let w = await CommandWorld()
        let run = try w.run("trap '' INT; exec sleep 30")
        #expect(await w.started(run))
        try await Task.sleep(nanoseconds: 150_000_000)
        w.store.stopRun(run.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(run.running) // el Ctrl+C no alcanzó
        #expect(await waitUntil { !run.running })
        #expect(run.exitCode != 0)
    }

    @Test("Correr de nuevo un comando terminado reutiliza su pestaña, con el comando actualizado")
    func rerunReusesTab() async throws {
        let w = await CommandWorld()
        let run = try w.run("echo primera")
        #expect(await waitUntil { !run.running })
        #expect(run.exitCode == 0)
        let command = try #require(w.store.project(w.project.id)?.commands.last)
        w.store.saveCommand(projectId: w.project.id, commandId: command.id, name: "Eco", command: "echo segunda; exec sleep 30")
        w.store.dockExpanded = false
        w.store.run(command.id, projectId: w.project.id)
        #expect(w.store.commandRuns.count == 1)
        #expect(w.store.commandRuns.first === run)
        #expect(run.running && run.command == "echo segunda; exec sleep 30" && run.name == "Eco")
        #expect(w.store.dockExpanded && w.store.dockRunId == run.id)
        #expect(await waitUntil { run.terminal?.fullText().contains("segunda") == true })
        w.store.closeRun(run.id)
    }

    @Test("Quitar una rama corta sus comandos y no deja runs huérfanos")
    func removingBranchStopsRuns() async throws {
        let w = await CommandWorld()
        #expect(await w.store.createBranch(NewBranchRequest(projectId: w.project.id, name: "wt", isNew: true, mode: .worktree)) == nil)
        let branch = try #require(w.store.project(w.project.id)?.branches.last)
        let inBranch = try w.run("exec sleep 30", branchId: branch.id)
        let inMain = try w.run("exec sleep 31", branchId: w.project.branches[0].id)
        #expect(await w.started(inBranch))
        #expect(await w.started(inMain))
        let terminal = try #require(inBranch.terminal)
        #expect(await w.store.performRemove(.branch(branch.id), deleteWorktree: true))
        #expect(w.store.commandRuns.map(\.id) == [inMain.id])
        #expect(await waitUntil { !terminal.isProcessRunning })
        #expect(inMain.running)
        w.store.closeRun(inMain.id)
    }

    @Test("Quitar un proyecto corta sus comandos")
    func removingProjectStopsRuns() async throws {
        let w = await CommandWorld()
        let run = try w.run("exec sleep 30")
        #expect(await w.started(run))
        let terminal = try #require(run.terminal)
        #expect(await w.store.performRemove(.project(w.project.id)))
        #expect(w.store.commandRuns.isEmpty)
        #expect(!w.store.dockExpanded)
        #expect(await waitUntil { !terminal.isProcessRunning })
    }
}
