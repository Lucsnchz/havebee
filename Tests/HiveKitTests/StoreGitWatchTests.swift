import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Dos repos («tienda», con un worktree, y «plagas»), git que cuenta las llamadas y avisos de
/// cambios que da el test. Al terminar de armarlo, todo está leído y no cambió nada.
@MainActor
private final class WatchedRepos {
    let world = TestWorld()
    let git = DelayedGit()
    let directories = FakeDirectories()
    let tienda = GitRepo(name: "tienda")
    let plagas = GitRepo(name: "plagas")
    let store: AppStore
    private(set) var worktree = ""

    init() async throws {
        world.git = git
        world.directories = directories
        world.appActive = true
        store = world.makeStore()
        await store.addProject(at: tienda.path)
        await store.addProject(at: plagas.path)
        let id = try #require(store.repoProjects.first { $0.name == "tienda" }?.id)
        #expect(await store.createBranch(NewBranchRequest(projectId: id, name: "pagos", isNew: true, mode: .worktree)) == nil)
        worktree = try #require(store.project(id)?.branches.first { $0.mode == .worktree }?.worktreePath)
        #expect(await settle())
        await store.refreshGitNow()
    }

    var tiendaProject: Project { store.repoProjects.first { $0.name == "tienda" }! }

    func settle() async -> Bool {
        await waitUntil { store.refreshTask == nil }
    }

    /// Cuántas veces corrió `git status` y cuántas se leyó la rama actual de un repo mientras corría `body`.
    func calls(_ body: () async -> Void) async -> (status: Int, heads: Int) {
        let status = git.calls(.status)
        let heads = git.calls(.currentBranch)
        await body()
        return (git.calls(.status) - status, git.calls(.currentBranch) - heads)
    }
}

@MainActor
@Suite("Store: git lee solo lo que cambió")
struct StoreGitWatchTests {
    @Test("Mira las carpetas de cada repo, sus worktrees y sus .git")
    func watchedRoots() async throws {
        let w = try await WatchedRepos()
        let tiendaGit = (w.tienda.path as NSString).appendingPathComponent(".git")
        let plagasGit = (w.plagas.path as NSString).appendingPathComponent(".git")
        #expect(w.directories.roots == [w.tienda.path, tiendaGit, w.worktree, w.plagas.path, plagasGit])
    }

    @Test("Si no cambió nada, la revisión no corre git")
    func nothingChanged() async throws {
        let w = try await WatchedRepos()
        let n = await w.calls { await w.store.refreshGitNow(.changed) }
        #expect(n == (0, 0))
    }

    @Test("Un cambio en los archivos de una carpeta lee solo su estado")
    func filesChanged() async throws {
        let w = try await WatchedRepos()
        w.tienda.write("nuevo.txt", "hola\n")
        w.directories.change(w.tienda.path)
        let n = await w.calls { await w.store.refreshGitNow(.changed) }
        #expect(n == (1, 0))
        let main = try #require(w.tiendaProject.branches.first { $0.mode == .main })
        #expect(w.store.gitStatus(for: main, in: w.tiendaProject)?.changes.map(\.path) == ["nuevo.txt"])
    }

    @Test("Un cambio en .git (un commit, un checkout) lee todo lo de ese repo, worktrees incluidos")
    func gitDataChanged() async throws {
        let w = try await WatchedRepos()
        w.directories.change((w.tienda.path as NSString).appendingPathComponent(".git"))
        let n = await w.calls { await w.store.refreshGitNow(.changed) }
        #expect(n == (2, 1))
    }

    @Test("Si macOS perdió avisos, lee todo")
    func lostEvents() async throws {
        let w = try await WatchedRepos()
        w.directories.loseEvents()
        let n = await w.calls { await w.store.refreshGitNow(.changed) }
        #expect(n == (3, 2))
    }

    @Test("Con la app activa lee lo que cambió, y todo cada 5 minutos")
    func periodic() async throws {
        let w = try await WatchedRepos()
        let quiet = await w.calls {
            w.store.periodicGitRefresh()
            _ = await w.settle()
        }
        #expect(quiet == (0, 0))
        w.world.advance(AppStore.fullGitRefreshInterval)
        let full = await w.calls {
            w.store.periodicGitRefresh()
            _ = await w.settle()
        }
        #expect(full == (3, 2))
    }

    @Test("Al volver a Hive lee solo lo que cambió mientras no estabas")
    func activation() async throws {
        let w = try await WatchedRepos()
        w.world.appActive = false
        w.directories.change(w.worktree)
        w.world.appActive = true
        let n = await w.calls {
            w.store.appBecameActive()
            _ = await w.settle()
        }
        #expect(n == (1, 0))
    }

    @Test("En segundo plano lee lo que cambió donde trabajan agentes; lo demás, al volver")
    func background() async throws {
        let w = try await WatchedRepos()
        let main = try #require(w.tiendaProject.branches.first { $0.mode == .main })
        w.store.requestNewSession(branchId: main.id, kind: .claude)
        let session = try #require(w.store.project(w.tiendaProject.id)?.branches.first { $0.id == main.id }?.sessions.first)
        w.store.activate(session.id)
        w.store.userInput(session.id, [13])
        #expect(w.store.runtimes[session.id]?.status == .working)

        w.world.appActive = false
        w.directories.change((w.tienda.path as NSString).appendingPathComponent(".git"))
        w.world.advance(61)
        let busy = await w.calls {
            w.store.periodicGitRefresh()
            _ = await w.settle()
        }
        #expect(busy == (1, 1)) // la carpeta principal, donde trabaja el agente

        // El worktree y las ramas del repo quedaron pendientes.
        w.world.appActive = true
        let rest = await w.calls {
            w.store.periodicGitRefresh()
            _ = await w.settle()
        }
        #expect(rest == (1, 1))
        #expect(w.git.calls(.worktrees) > 0)
    }
}
