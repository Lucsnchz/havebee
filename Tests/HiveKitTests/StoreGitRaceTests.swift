import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Un store con git lento a pedido, para provocar carreras entre la revisión y lo que hace Hive.
@MainActor
private struct RaceSetup {
    let world = TestWorld()
    let git = DelayedGit()
    let repo = GitRepo()
    let store: AppStore

    init() async {
        world.git = git
        store = world.makeStore()
        await store.addProject(at: repo.path)
        _ = await waitUntil { store.refreshTask == nil }
    }

    var project: Project { store.repoProjects[0] }

    /// Espera a que termine la revisión en curso (y las que se pidieron mientras tanto).
    func settle() async -> Bool {
        await waitUntil(timeout: 10) { store.refreshTask == nil }
    }

    /// Le da tiempo a la revisión para leer git antes de cambiar algo.
    func letItRead() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
}

@MainActor
@Suite("Store: carreras de git")
struct StoreGitRaceTests {
    @Test("Agregar proyecto durante una revisión mantiene la rama activa")
    func addDuringRefresh() async throws {
        let s = await RaceSetup()
        let second = GitRepo(name: "segundo")
        s.git.setDelay(.worktrees, 0.6)
        s.store.refreshGit()
        await s.letItRead()
        s.git.setDelay(.worktrees, 0)
        await s.store.addProject(at: second.path)
        #expect(await s.settle())
        let added = try #require(s.store.repoProjects.first { $0.name == "segundo" })
        #expect(s.store.mainHead(of: added.id) == "main")
        #expect(s.store.isActive(added.branches[0], in: added))
        #expect(s.store.mainHead(of: s.project.id) == "main")
    }

    @Test("Checkout durante una revisión no vuelve al HEAD viejo")
    func checkoutDuringRefresh() async throws {
        let s = await RaceSetup()
        #expect(await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "fix", isNew: true, mode: .main)) == nil)
        #expect(await s.settle())
        let fix = try #require(s.store.project(s.project.id)?.branches.first { $0.name == "fix" })

        s.git.setDelay(.currentBranch, 0.6)
        s.store.refreshGit()
        await s.letItRead() // ya leyó «main» y está esperando
        s.git.setDelay(.currentBranch, 0)
        s.store.requestCheckout(branchId: fix.id)
        #expect(await s.store.performCheckout(try #require(s.store.pendingCheckout)))
        #expect(s.store.mainHead(of: s.project.id) == "fix")
        #expect(await s.settle())
        #expect(s.store.mainHead(of: s.project.id) == "fix")
        #expect(s.store.isActive(fix, in: try #require(s.store.project(s.project.id))))
    }

    @Test("Un pedido durante una revisión dispara otra pasada al terminar")
    func requestDuringRefresh() async throws {
        let s = await RaceSetup()
        s.git.setDelay(.currentBranch, 0.5)
        s.store.refreshGit()
        await s.letItRead()
        s.repo.sh("git checkout -q -b otra") // alguien cambia de rama por fuera
        s.store.refreshGit() // y Hive se entera (por ejemplo, al volver a la app)
        s.git.setDelay(.currentBranch, 0)
        #expect(await s.settle())
        #expect(s.store.mainHead(of: s.project.id) == "otra")
    }

    @Test("El estado de git se fusiona por carpeta y olvida los proyectos quitados")
    func mergesAndPrunes() async throws {
        let s = await RaceSetup()
        let second = GitRepo(name: "segundo")
        await s.store.addProject(at: second.path)
        #expect(await s.settle())
        await s.store.refreshGitNow()
        let added = try #require(s.store.repoProjects.first { $0.name == "segundo" })
        #expect(s.store.dirStatus[second.path] != nil)
        #expect(await s.store.performRemove(.project(added.id)))
        await s.store.refreshGitNow()
        #expect(s.store.dirStatus[second.path] == nil)
        #expect(s.store.mainHeads[added.id] == nil)
        #expect(s.store.dirStatus[s.repo.path] != nil)
    }
}
