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
        await waitUntil { store.refreshTask == nil }
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

    @Test("Una revisión en medio de un checkout de Hive no lo toma como un cambio de afuera")
    func refreshDuringCheckout() async throws {
        let s = await RaceSetup()
        #expect(await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "fix", isNew: true, mode: .main)) == nil)
        #expect(await s.settle())
        let main = s.project.branches[0]
        let fix = try #require(s.store.project(s.project.id)?.branches.first { $0.name == "fix" })
        // Una sesión corriendo en main: si la revisión creyera que la rama cambió por fuera, preguntaría.
        s.store.requestNewSession(branchId: main.id, kind: .shell)
        let session = try #require(s.store.branchContext(main.id)?.branch.sessions.last)
        s.store.activate(session.id)
        #expect(s.store.runtimes[session.id]?.isRunning == true)

        // El checkout tarda: git ya cambió de rama, pero Hive todavía no recibió la respuesta.
        s.git.setDelay(.checkout, 0.6)
        s.store.requestCheckout(branchId: fix.id)
        let pending = try #require(s.store.pendingCheckout)
        let checkout = Task { await s.store.performCheckout(pending) }
        await s.letItRead()
        await s.store.refreshGitNow() // la revisión del timer cae justo en el medio
        #expect(s.store.alert == nil)
        #expect(await checkout.value)
        #expect(await s.settle())
        #expect(s.store.alert == nil)
        #expect(s.store.mainHead(of: s.project.id) == "fix")
        #expect(s.store.isActive(fix, in: try #require(s.store.project(s.project.id))))
    }

    @Test("Un checkout que falla igual pide otra revisión (la que estaba en curso se descartó)")
    func failedCheckoutRefreshes() async throws {
        let s = await RaceSetup()
        #expect(await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "fix", isNew: true, mode: .main)) == nil)
        #expect(await s.settle())
        let fix = try #require(s.store.project(s.project.id)?.branches.first { $0.name == "fix" })
        s.repo.sh("git branch -q -D fix") // la rama ya no existe en git: el checkout va a fallar
        s.store.requestCheckout(branchId: fix.id)
        let pending = try #require(s.store.pendingCheckout)
        #expect(!(await s.store.performCheckout(pending)))
        #expect(s.store.alert?.title == "No pude hacer checkout de «fix»")
        #expect(s.store.refreshTask != nil)
        #expect(await s.settle())
    }

    @Test("Quitar una rama borrando el worktree no deja arrancar una sesión que se estaba armando")
    func removeWhileLaunching() async throws {
        let s = await RaceSetup()
        #expect(await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "wt", isNew: true, mode: .worktree)) == nil)
        #expect(await s.settle())
        let branch = try #require(s.store.project(s.project.id)?.branches.last)
        s.store.requestNewSession(branchId: branch.id, kind: .shell)
        let session = try #require(s.store.branchContext(branch.id)?.branch.sessions.last)
        // Con el lanzamiento en segundo plano, como en la app.
        var environment = s.world.environment
        environment.launchesInBackground = true
        let store = AppStore(environment: environment)
        let rt = try #require(store.runtimes[session.id])
        await store.refreshGitNow()
        s.git.setDelay(.removeWorktree, 0.5) // git tarda en borrar: el armado del lanzamiento termina antes
        store.activate(session.id)
        #expect(rt.isLaunching)
        let removed = Task { await store.performRemove(.branch(branch.id), deleteWorktree: true) }
        #expect(await waitUntil { !rt.isLaunching })
        #expect(!rt.isRunning) // se cortó para borrar la carpeta: no arranca ahí
        #expect(await removed.value)
        #expect(s.world.processes.launches.isEmpty)
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

@MainActor
@Suite("Store: revisión de git liviana")
struct StoreGitScheduleTests {
    @Test("En segundo plano revisa cada 60 s y solo las carpetas con agentes trabajando")
    func backgroundRefresh() async throws {
        let s = await RaceSetup()
        s.world.appActive = false
        let before = s.git.calls(.status)
        s.store.periodicGitRefresh()
        #expect(await s.settle())
        #expect(s.git.calls(.status) == before) // nadie trabaja: no corre git

        s.store.requestNewSession(branchId: s.project.branches[0].id, kind: .claude)
        let session = try #require(s.store.project(s.project.id)?.allSessions.first)
        s.store.activate(session.id)
        s.store.userInput(session.id, [13])
        #expect(s.store.runtimes[session.id]?.status == .working)
        s.world.advance(61)
        s.store.periodicGitRefresh()
        #expect(await s.settle())
        #expect(s.git.calls(.status) == before + 1)
        #expect(s.git.calls(.worktrees) > 0)
        let worktreeCalls = s.git.calls(.worktrees)

        s.world.advance(30)
        s.store.periodicGitRefresh() // todavía no pasó un minuto
        #expect(await s.settle())
        #expect(s.git.calls(.status) == before + 1)

        s.world.advance(31)
        s.store.periodicGitRefresh()
        #expect(await s.settle())
        #expect(s.git.calls(.status) == before + 2)
        #expect(s.git.calls(.worktrees) == worktreeCalls) // en segundo plano no busca worktrees nuevos
    }

    @Test("Con la app activa revisa todo cada vez")
    func foregroundRefresh() async throws {
        let s = await RaceSetup()
        s.world.appActive = true
        let before = s.git.calls(.status)
        s.store.periodicGitRefresh()
        #expect(await s.settle())
        s.store.periodicGitRefresh()
        #expect(await s.settle())
        #expect(s.git.calls(.status) == before + 2)
    }

    @Test("Muchas carpetas se revisan en paralelo y sin perder ninguna")
    func parallelScan() async throws {
        let s = await RaceSetup()
        for i in 1...6 {
            #expect(await s.store.createBranch(NewBranchRequest(projectId: s.project.id, name: "wt-\(i)", isNew: true, mode: .worktree)) == nil)
        }
        #expect(await s.settle())
        // Cada status tarda 0,3 s: así las llamadas se superponen y se puede ver cuántas corren a la vez
        // (contarlas no depende de lo cargada que esté la máquina, medir el tiempo sí).
        let git = DelayedGit()
        git.setDelay(.status, 0.3)
        var environment = s.world.environment
        environment.git = git
        let store = AppStore(environment: environment)
        await store.refreshGitNow()
        let project = try #require(store.project(s.project.id))
        #expect(project.branches.count == 7)
        for branch in project.branches {
            #expect(store.gitStatus(for: branch, in: project) != nil, "Falta \(branch.name)")
        }
        #expect(git.calls(.status) == 7)
        #expect(git.peakConcurrency > 1) // en paralelo...
        #expect(git.peakConcurrency <= 4) // ...pero como mucho 4 a la vez
    }

    @Test("Al cargar no lee git y la sesión abierta se lanza cuando su rama pasa a estar activa")
    func selectedSessionLaunchesAfterFirstRefresh() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let session = Session(name: "Terminal 1", kind: .shell)
        let project = Project(name: "repo", path: repo.path, branches: [Branch(name: "main", mode: .main, sessions: [session])])
        try StateStore(file: world.paths.stateFile).save(HiveState(projects: [project], selection: .session(session.id)))
        let git = DelayedGit()
        world.git = git
        let store = world.makeStore()
        #expect(git.calls(.currentBranch) == 0)
        store.activate(session.id) // la vista aparece antes de saber la rama: no se puede lanzar
        #expect(world.processes.launches.isEmpty)
        await store.refreshGitNow()
        #expect(store.runtimes[session.id]?.isRunning == true)
        #expect(world.processes.launches.count == 1)
    }

    /// Un estado guardado con la carpeta principal en «main» y dos sesiones ahí; la primera abierta.
    private func savedOnMain(_ world: TestWorld, _ repo: GitRepo) throws -> (project: Project, open: Session, other: Session) {
        let open = Session(name: "Claude 1", kind: .claude), other = Session(name: "Claude 2", kind: .claude)
        let project = Project(name: "repo", path: repo.path, branches: [Branch(name: "main", mode: .main, sessions: [open, other])])
        try StateStore(file: world.paths.stateFile).save(HiveState(projects: [project], selection: .session(open.id),
                                                                   mainHeads: [project.id: "main"]))
        return (project, open, other)
    }

    @Test("Con la rama guardada vieja, la sesión abierta no arranca en otra rama")
    func staleSavedHeadDoesNotLaunch() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let saved = try savedOnMain(world, repo)
        repo.sh("git checkout -q -b otra") // con Hive cerrado, alguien cambió de rama
        let store = world.makeStore()
        #expect(store.isActive(saved.project.branches[0], in: saved.project)) // lo guardado dice que sí...
        store.activate(saved.open.id)
        #expect(world.processes.launches.isEmpty) // ...pero hasta que git lo confirme no se lanza
        await store.refreshGitNow()
        #expect(store.mainHead(of: saved.project.id) == "otra")
        #expect(world.processes.launches.isEmpty)
        #expect(store.runtimes[saved.open.id]?.status == .dormant)
        #expect(store.alert == nil) // no corría nada: no hay sesiones para mover
    }

    @Test("Con la rama guardada bien, la sesión abierta arranca apenas git la confirma")
    func confirmedSavedHeadLaunches() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let saved = try savedOnMain(world, repo)
        let store = world.makeStore()
        store.activate(saved.other.id) // la miraste un momento y te fuiste a otra
        store.activate(saved.open.id)
        #expect(world.processes.launches.isEmpty)
        await store.refreshGitNow()
        #expect(store.runtimes[saved.open.id]?.isRunning == true)
        #expect(store.runtimes[saved.other.id]?.isRunning == false)
        #expect(world.processes.launches.count == 1)
        // Ya confirmada, abrir otra la lanza enseguida.
        store.select(.session(saved.other.id))
        store.activate(saved.other.id)
        #expect(world.processes.launches.count == 2)
    }

    @Test("Al arrancar, la rama se confirma sin esperar los git status (que pueden tardar)")
    func quickHeadConfirmation() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let saved = try savedOnMain(world, repo)
        let git = DelayedGit()
        world.git = git
        let store = world.makeStore()
        store.activate(saved.open.id)
        #expect(world.processes.launches.isEmpty)
        await store.confirmSavedHeads()
        #expect(store.runtimes[saved.open.id]?.isRunning == true)
        #expect(git.calls(.status) == 0 && git.calls(.worktrees) == 0) // solo leyó la rama
        #expect(git.calls(.currentBranch) == 1)

        // Con la rama cambiada por fuera, tampoco hace falta la revisión completa para no lanzarla.
        let other = TestWorld()
        let moved = GitRepo()
        let stale = try savedOnMain(other, moved)
        moved.sh("git checkout -q -b otra")
        let second = other.makeStore()
        second.activate(stale.open.id)
        await second.confirmSavedHeads()
        #expect(second.mainHead(of: stale.project.id) == "otra")
        #expect(other.processes.launches.isEmpty)
    }
}
