import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Un repo con .env ignorado y un polyscope.json con scripts de preparación y de cierre.
@MainActor
private struct WorktreeScriptsSetup {
    let world = TestWorld()
    let repo = GitRepo(name: "tienda")
    let store: AppStore
    let project: Project

    init(archive: String? = nil) async throws {
        repo.write(".gitignore", ".env\nauth.json\n")
        repo.commit("Ignorados")
        repo.write(".env", "APP_URL=https://tienda.test\n")
        repo.write("auth.json", "{}")
        if let archive {
            repo.write("polyscope.json", #"{"scripts": {"archive": "\#(archive)"}}"#)
        }
        store = world.makeStore()
        await store.addProject(at: repo.path)
        project = try #require(store.repoProjects.first)
    }

    func createWorktree(_ name: String, copyIgnored: Bool = true, setup: String? = nil) async throws -> Branch {
        let error = await store.createBranch(NewBranchRequest(projectId: project.id, name: name, isNew: true, mode: .worktree,
                                                              copyIgnored: copyIgnored, setupCommand: setup))
        #expect(error == nil)
        return try #require(store.project(project.id)?.branches.first { $0.name == name })
    }

    /// El script suelto que se lanzó con ese nombre.
    func script(_ name: String) -> CommandRun? {
        store.commandRuns.first { $0.isScript && $0.name == name }
    }

    func launch(of run: CommandRun) -> FakeProcesses.Launch? {
        world.processes.launches.last { $0.args.last == run.command && $0.directory == run.directory }
    }
}

@MainActor
@Suite("Store: scripts de los worktrees")
struct StoreWorktreeScriptsTests {
    @Test("Un worktree nuevo corre «Preparar» en su carpeta, con el entorno HIVE_*, y avisa qué copió")
    func setupRunsAndCopiedNotice() async throws {
        let s = try await WorktreeScriptsSetup()
        let branch = try await s.createWorktree("feature-x", setup: "composer install && npm install")
        let path = try #require(branch.worktreePath)
        let run = try #require(s.script("Preparar feature-x"))
        #expect(run.command == "composer install && npm install")
        #expect(run.directory == path)
        #expect(run.branchId == branch.id)
        let launch = try #require(s.launch(of: run))
        #expect(launch.args == ["-l", "-i", "-c", "composer install && npm install"])
        #expect(launch.environment["HIVE_ROOT_PATH"] == s.repo.path)
        #expect(launch.environment["HIVE_WORKTREE_PATH"] == path)
        #expect(launch.environment["HIVE_BRANCH"] == "feature-x")
        #expect(launch.environment["CONDUCTOR_ROOT_PATH"] == s.repo.path)
        #expect(s.store.dockRunId == run.id)
        // Se copiaron los ignorados y lo dice la cápsula (sin «Deshacer»).
        #expect(FileManager.default.fileExists(atPath: path + "/.env"))
        let notice = try #require(s.store.undoAction)
        #expect(notice.message == "Copié .env y auth.json a «feature-x»")
        #expect(!notice.canUndo)
        s.store.performUndo() // no hace nada, solo la cierra
        #expect(s.store.undoAction == nil)
        #expect(s.store.project(s.project.id)?.branches.contains { $0.name == "feature-x" } == true)
    }

    @Test("Con la casilla «Preparar» apagada no corre nada; si no copió nada, no avisa")
    func noSetupNoNotice() async throws {
        let s = try await WorktreeScriptsSetup()
        _ = try await s.createWorktree("sin-preparar", copyIgnored: false, setup: nil)
        #expect(s.store.commandRuns.isEmpty)
        #expect(s.store.undoAction == nil)
    }

    @Test("Antes de borrar un worktree corre su script de cierre ahí y espera que termine")
    func archiveRunsBeforeRemoving() async throws {
        let s = try await WorktreeScriptsSetup(archive: "herd unsecure tienda-feature")
        let branch = try await s.createWorktree("feature-x", copyIgnored: false)
        let path = try #require(branch.worktreePath)
        let removal = Task { await s.store.performRemove(.branch(branch.id), deleteWorktree: true) }
        #expect(await waitUntil { s.script("Cerrar feature-x") != nil })
        let run = try #require(s.script("Cerrar feature-x"))
        #expect(run.command == "herd unsecure tienda-feature")
        #expect(run.directory == path)
        let launch = try #require(s.launch(of: run))
        #expect(launch.environment["HIVE_WORKTREE_PATH"] == path)
        #expect(launch.environment["HIVE_BRANCH"] == "feature-x")
        // Mientras corre, la carpeta sigue ahí.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(s.store.project(s.project.id)?.branches.count == 2)
        // Termina bien: recién ahí se borra.
        s.store.commandExited(run.id, terminal: try #require(run.terminal), code: 0)
        #expect(await removal.value)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(s.store.project(s.project.id)?.branches.count == 1)
        #expect(s.store.commandRuns.isEmpty) // se cerró con la rama
        #expect(s.store.alert == nil)
    }

    @Test("Si el cierre falla, avisa con el código y borra igual")
    func archiveFailureWarns() async throws {
        let s = try await WorktreeScriptsSetup(archive: "docker compose down")
        let branch = try await s.createWorktree("feature-x", copyIgnored: false)
        let path = try #require(branch.worktreePath)
        let removal = Task { await s.store.performRemove(.branch(branch.id), deleteWorktree: true) }
        #expect(await waitUntil { s.script("Cerrar feature-x") != nil })
        let run = try #require(s.script("Cerrar feature-x"))
        s.store.commandExited(run.id, terminal: try #require(run.terminal), code: 1)
        #expect(await removal.value)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(s.store.alert?.title == "La limpieza de «feature-x» terminó con error (código 1)")
        #expect(s.store.alert?.message.hasPrefix("docker compose down") == true)
    }

    @Test("Si el cierre tarda de más, se corta y el borrado sigue")
    func archiveTimeout() async throws {
        let s = try await WorktreeScriptsSetup(archive: "sleep 600")
        s.store.archiveTimeout = 0.3
        let branch = try await s.createWorktree("feature-x", copyIgnored: false)
        let path = try #require(branch.worktreePath)
        #expect(await s.store.performRemove(.branch(branch.id), deleteWorktree: true))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(s.store.alert?.title == "La limpieza de «feature-x» tardó demasiado")
    }

    @Test("Sin script de cierre, o quitando la rama sin borrar la carpeta, no corre nada")
    func noArchiveScript() async throws {
        let s = try await WorktreeScriptsSetup(archive: "echo chau")
        let kept = try await s.createWorktree("se-queda", copyIgnored: false)
        #expect(await s.store.performRemove(.branch(kept.id), deleteWorktree: false))
        #expect(s.store.commandRuns.isEmpty)

        let plain = try await WorktreeScriptsSetup()
        let branch = try await plain.createWorktree("feature-x", copyIgnored: false)
        #expect(await plain.store.performRemove(.branch(branch.id), deleteWorktree: true))
        #expect(plain.world.processes.launches.isEmpty)
    }

    @Test("lastLines: las últimas líneas con texto")
    func lastLines() {
        #expect(AppStore.lastLines("uno\n\n  dos  \ntres\n", count: 2) == "dos\ntres")
        #expect(AppStore.lastLines("", count: 3) == "")
    }
}
