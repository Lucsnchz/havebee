import AppKit
import Foundation
import HiveCore
import Testing
import UniformTypeIdentifiers
@testable import HiveKit

/// Un mundo con proyectos guardados de antes (sin git: el orden no lo necesita).
/// «viejo» no se usa hace una semana, «hoy» tiene una sesión de hoy y «fijado» está fijado.
@MainActor
private final class RielWorld {
    let world = TestWorld()
    let old: Project
    let today: Project
    let pinned: Project

    init() throws {
        let lastWeek = world.now.addingTimeInterval(-7 * 86_400)
        old = Project(name: "viejo", path: "/viejo", branches: [Branch(name: "main", mode: .main, sessions: [
            Session(name: "Claude 1", kind: .claude, createdAt: lastWeek),
        ])])
        today = Project(name: "hoy", path: "/hoy", branches: [Branch(name: "main", mode: .main, sessions: [
            Session(name: "Codex 1", kind: .codex, createdAt: world.now),
        ])])
        pinned = Project(name: "fijado", path: "/fijado", branches: [Branch(name: "main", mode: .main)], pinned: true)
        try StateStore(file: world.paths.stateFile).save(HiveState(projects: [old, today, pinned]))
    }

    func makeStore() -> AppStore { world.makeStore() }
}

/// Una marca que se puede prender desde el aviso de Observation.
private final class RielFlag: @unchecked Sendable {
    var value = false
}

/// Tres repos con git en orden manual [b, a, c]: «a» y «c» con un Claude creado hoy, «b» con uno
/// creado la semana pasada. Nada corre: como al abrir Hive a la mañana.
@MainActor
private final class ThreeRepos {
    let world = TestWorld()
    let repos = [GitRepo(name: "b"), GitRepo(name: "a"), GitRepo(name: "c")]
    let store: AppStore
    var a: Project!
    var b: Project!
    var c: Project!
    var lastWeek: Date { world.now.addingTimeInterval(-7 * 86_400) }

    init() async throws {
        store = world.makeStore()
        for repo in repos { await store.addProject(at: repo.path) }
        b = try #require(store.repoProjects.first { $0.name == "b" })
        a = try #require(store.repoProjects.first { $0.name == "a" })
        c = try #require(store.repoProjects.first { $0.name == "c" })
        try newSession(in: b, .claude, at: lastWeek)
        try newSession(in: a, .claude)
        try newSession(in: c, .claude)
        store.select(nil)
    }

    /// Crea una sesión (en `date`, o ahora) y devuelve su id.
    @discardableResult
    func newSession(in project: Project, _ kind: SessionKind, at date: Date? = nil) throws -> UUID {
        let today = world.now
        if let date { world.now = date }
        defer { world.now = today }
        store.requestNewSession(branchId: project.branches[0].id, kind: kind)
        return try #require(store.project(project.id)?.activeSessions.last?.id)
    }

    func session(of project: Project) throws -> UUID {
        try #require(store.project(project.id)?.activeSessions.first?.id)
    }

    var names: [String] { store.visibleProjects.map(\.project.name) }
    func group(_ project: Project) -> ProjectOrdering.Group? { store.visibleProjects.first { $0.id == project.id }?.group }
}

@MainActor
@Suite("Orden de los proyectos en el store")
struct StoreProjectOrderTests {
    @Test("Fijados, activos de hoy, apagados y «Terminales»: el mismo orden para todos")
    func visibleOrder() throws {
        let w = try RielWorld()
        let store = w.makeStore()
        #expect(store.visibleProjects.map(\.project.name) == ["fijado", "hoy", "viejo", "Terminales"])
        #expect(store.visibleProjects.map(\.group) == [.pinned, .active, .idle, .scratch])
        // El fijado no tiene sesiones: está arriba pero atenuado.
        #expect(store.visibleProjects.map(\.isActive) == [false, true, false, false])
        #expect(HiveNavigator.orderedProjects(store).map(\.name) == ["fijado", "hoy", "viejo", "Terminales"])
    }

    @Test("Una sesión prendida (o que te espera) sube su proyecto a los activos, aunque sea vieja")
    func liveSessionIsActive() throws {
        let w = try RielWorld()
        let store = w.makeStore()
        let session = try #require(w.old.activeSessions.first)
        store.runtimes[session.id]?.unseen = true
        #expect(store.visibleProjects.map(\.project.name) == ["fijado", "viejo", "hoy", "Terminales"])
        #expect(store.visibleProjects[1].isActive)

        // Lo que tiene aro (trabajando, permiso o sin ver) nunca queda entre los apagados.
        store.runtimes[session.id]?.unseen = false
        #expect(store.visibleProjects.map(\.project.name) == ["fijado", "hoy", "viejo", "Terminales"])
        for status in [SessionStatus.working, .attention] {
            store.runtimes[session.id]?.status = status
            #expect(store.visibleProjects.first { $0.id == w.old.id }?.group == .active)
        }
        for item in store.visibleProjects where !item.isActive {
            #expect(store.activity(of: item.project).ring == .none)
        }
    }

    @Test("Abrir un proyecto apagado (riel, ⌃⌘N, ⌘K) no lo cambia de lugar: ⌃⌘N le sigue apuntando")
    func openingIdleProjectStaysPut() async throws {
        let w = try await ThreeRepos()
        let store = w.store
        #expect(w.names == ["a", "c", "b", "Terminales"])
        #expect(w.group(w.b) == .idle)

        // ⌃⌘3 abre «b» y su vista lanza la sesión (SessionDetailView → activate), como un clic en el riel.
        HiveNavigator.goToProject(store, index: 2)
        #expect(store.currentProjectId == w.b.id)
        let session = try w.session(of: w.b)
        store.activate(session)
        #expect(store.runtimes[session]?.isRunning == true)
        // Corre, pero nadie la usó: sigue entre los apagados y en su lugar (sin atenuar, porque está abierto).
        #expect(w.names == ["a", "c", "b", "Terminales"])
        #expect(w.group(w.b) == .idle)
        HiveNavigator.goToProject(store, index: 2)
        #expect(store.currentProjectId == w.b.id)
        store.openProject(w.a.id)
        store.openProject(w.b.id)
        #expect(w.names == ["a", "c", "b", "Terminales"])

        // Le escribís al agente: eso sí es usarlo, y sube a los activos (a su lugar del orden manual).
        store.userInput(session, [13][...])
        #expect(store.runtimes[session]?.status == .working)
        #expect(w.names == ["b", "a", "c", "Terminales"])
    }

    @Test("Un agente o una Terminal que quedaron abiertos días sin hacer nada no prenden el proyecto")
    func openForDaysIsIdle() async throws {
        let w = try await ThreeRepos()
        let store = w.store
        let claude = try w.session(of: w.b)
        let shell = try w.newSession(in: w.b, .shell, at: w.lastWeek)
        for id in [claude, shell] {
            store.activate(id)
            #expect(store.runtimes[id]?.isRunning == true)
        }
        store.select(nil)
        #expect(w.group(w.b) == .idle)
        #expect(store.visibleProjects.first { $0.id == w.b.id }?.isActive == false)
        #expect(store.activity(of: try #require(store.project(w.b.id))).ring == .none)

        // Tres días después, con Hive abierto todo el tiempo: «a» y «c» también se apagan.
        for project in [w.a!, w.c!] { store.activate(try w.session(of: project)) }
        store.select(nil)
        w.world.advance(3 * 86_400)
        store.dayChanged()
        #expect(store.visibleProjects.map(\.group) == [.idle, .idle, .idle, .scratch])
        #expect(w.names == ["b", "a", "c", "Terminales"])
    }

    @Test("Escribirle a un agente lo cuenta como usado hoy, también sin hooks (Gemini): no se apaga al terminar")
    func typingCountsAsUse() async throws {
        let w = try await ThreeRepos()
        let store = w.store
        let gemini = try w.newSession(in: w.b, .gemini, at: w.lastWeek)
        store.activate(gemini)
        let rt = try #require(store.runtimes[gemini])
        #expect(w.group(w.b) == .idle)
        store.userInput(gemini, [13][...])
        #expect(store.sessionContext(gemini)?.session.lastActivityAt == w.world.now)
        // Terminó (Esc, o la regla del silencio) y la estabas mirando: sin aro, pero se usó hoy.
        store.userInput(gemini, [0x1B][...])
        #expect(rt.status == .waiting && !rt.unseen)
        #expect(w.group(w.b) == .active)
        // Las teclas sueltas no cuentan: solo mandar algo (Enter).
        let before = store.sessionContext(gemini)?.session.lastActivityAt
        w.world.advance(60)
        store.userInput(gemini, Array("hola".utf8)[...])
        #expect(store.sessionContext(gemini)?.session.lastActivityAt == before)
    }

    @Test("Al cambiar el día, lo de ayer pasa a los apagados")
    func dayChange() async throws {
        let w = try RielWorld()
        let store = w.makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: w.world.now)))
        w.world.now = tomorrow.addingTimeInterval(60)
        var env = w.world.environment
        env.calendar = calendar
        let next = AppStore(environment: env)
        #expect(next.visibleProjects.map(\.project.name) == ["fijado", "viejo", "hoy", "Terminales"])
        #expect(next.visibleProjects.map(\.group) == [.pinned, .idle, .idle, .scratch])

        // El aviso del sistema hace que las vistas lo recalculen (sin timers).
        let before = store.dayStamp
        store.observeDayChanges()
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        #expect(await waitUntil { store.dayStamp > before })
    }

    @Test("Quien lee el orden (el riel, el árbol, el menú Ir) se entera solo del cambio de día")
    func dayChangeInvalidatesReaders() throws {
        let w = try RielWorld()
        let store = w.makeStore()
        let changed = RielFlag()
        withObservationTracking { _ = store.visibleProjects } onChange: { changed.value = true }
        #expect(!changed.value)
        store.dayChanged()
        #expect(changed.value)

        // Y el orden nuevo sale de la hora actual: días después, «hoy» ya pasó a los apagados.
        #expect(store.visibleProjects.first { $0.id == w.today.id }?.group == .active)
        w.world.now = w.world.now.addingTimeInterval(2 * 86_400)
        #expect(store.visibleProjects.first { $0.id == w.today.id }?.group == .idle)
    }

    @Test("Fijar y desfijar se guardan, y el fijado queda último de los fijados")
    func pinPersists() throws {
        let w = try RielWorld()
        let store = w.makeStore()
        store.setPinned(true, project: w.old.id)
        #expect(store.visibleProjects.map(\.project.name) == ["fijado", "viejo", "hoy", "Terminales"])
        #expect(store.project(w.old.id)?.pinned == true)

        let reloaded = w.makeStore()
        #expect(reloaded.project(w.old.id)?.pinned == true)
        #expect(reloaded.visibleProjects.map(\.project.name) == ["fijado", "viejo", "hoy", "Terminales"])

        reloaded.setPinned(false, project: w.pinned.id)
        #expect(w.makeStore().visibleProjects.map(\.project.name) == ["viejo", "hoy", "fijado", "Terminales"])
        #expect(w.makeStore().project(w.pinned.id)?.pinned == false)

        // «Terminales» no se fija.
        let scratch = try #require(reloaded.scratchProject)
        reloaded.setPinned(true, project: scratch.id)
        #expect(reloaded.scratchProject?.pinned == false)
    }

    @Test("Un state.json de antes (sin «pinned») carga igual")
    func legacyStateLoads() throws {
        let world = TestWorld()
        let json = """
        {"expanded": [], "selection": null, "projects": [{
          "id": "11111111-1111-1111-1111-111111111111", "name": "viejo", "path": "/repo",
          "branches": [{"id": "22222222-2222-2222-2222-222222222222", "name": "main", "mode": "main", "sessions": []}]
        }]}
        """
        try FileManager.default.createDirectory(at: world.paths.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: world.paths.stateFile)
        let store = world.makeStore()
        #expect(store.alert == nil)
        #expect(store.repoProjects.map(\.name) == ["viejo"])
        #expect(store.repoProjects.first?.pinned == false)
    }

    @Test("⌃⌘N abre el proyecto N del orden que se ve, y ⌥⌘↓ / ⌥⌘↑ lo siguen")
    func projectShortcuts() throws {
        let w = try RielWorld()
        let store = w.makeStore()
        HiveNavigator.goToProject(store, index: 0)
        #expect(store.currentProjectId == w.pinned.id)
        HiveNavigator.goToProject(store, index: 1)
        #expect(store.currentProjectId == w.today.id)
        HiveNavigator.goToProject(store, index: 2)
        #expect(store.currentProjectId == w.old.id)
        HiveNavigator.goToProject(store, index: 3)
        #expect(store.currentProjectId == store.scratchProject?.id)
        HiveNavigator.goToProject(store, index: 4) // no existe: no cambia nada
        #expect(store.currentProjectId == store.scratchProject?.id)

        HiveNavigator.goToAdjacentProject(store, delta: 1) // da la vuelta
        #expect(store.currentProjectId == w.pinned.id)
        HiveNavigator.goToAdjacentProject(store, delta: 1)
        #expect(store.currentProjectId == w.today.id)
        HiveNavigator.goToAdjacentProject(store, delta: -1)
        #expect(store.currentProjectId == w.pinned.id)

        // Al fijar otro, los atajos siguen el orden nuevo.
        store.setPinned(true, project: w.old.id)
        HiveNavigator.goToProject(store, index: 1)
        #expect(store.currentProjectId == w.old.id)
    }

    @Test("Arrastrar y «Subir» / «Bajar» mueven dentro del grupo y guardan el orden que se ve")
    func moveWithinGroup() throws {
        let w = try RielWorld()
        let store = w.makeStore()
        store.setPinned(true, project: w.today.id)
        #expect(store.visibleProjects.map(\.project.name) == ["fijado", "hoy", "viejo", "Terminales"])
        #expect(try #require(store.position(of: .project(w.today.id))) == (1, 2))
        #expect(try #require(store.position(of: .project(w.old.id))) == (0, 1))
        #expect(store.position(of: .project(try #require(store.scratchProject?.id))) == nil)

        store.moveProjects(in: .pinned, from: [1], to: 0)
        #expect(store.projects.map(\.name) == ["hoy", "fijado", "viejo", "Terminales"])
        #expect(w.makeStore().projects.map(\.name) == ["hoy", "fijado", "viejo", "Terminales"])

        // «viejo» es el único apagado: no sube a los fijados.
        store.move(.project(w.old.id), by: -1)
        #expect(store.projects.map(\.name) == ["hoy", "fijado", "viejo", "Terminales"])
        store.move(.project(w.pinned.id), by: -1)
        #expect(store.projects.map(\.name) == ["fijado", "hoy", "viejo", "Terminales"])
        store.moveProjects(in: .scratch, from: [0], to: 0) // «Terminales» no se mueve
        #expect(store.projects.last?.isScratch == true)
    }

    @Test("Arrastrar en el riel: toma el lugar del otro dentro del grupo y se guarda")
    func dragInRail() throws {
        let w = try RielWorld()
        let store = w.makeStore()
        store.setPinned(true, project: w.old.id)
        #expect(store.visibleProjects.map(\.project.name) == ["fijado", "viejo", "hoy", "Terminales"])
        #expect(store.moveProject(w.old.id, onto: w.pinned.id))
        #expect(store.visibleProjects.map(\.project.name) == ["viejo", "fijado", "hoy", "Terminales"])
        #expect(w.makeStore().visibleProjects.map(\.project.name) == ["viejo", "fijado", "hoy", "Terminales"])
        // «hoy» no es fijado: no se mete entre ellos (y el riel no deja soltarlo ahí).
        #expect(store.canMoveProject(w.old.id, onto: w.pinned.id))
        #expect(!store.canMoveProject(w.today.id, onto: w.old.id))
        #expect(!store.moveProject(w.today.id, onto: w.old.id))
        #expect(store.visibleProjects.map(\.project.name) == ["viejo", "fijado", "hoy", "Terminales"])
    }

    @Test("El arrastre del riel usa un tipo propio: soltarlo en una terminal no escribe nada")
    func railDragType() {
        let type = RailReorderDelegate.type
        #expect(!TerminalDrop.types.map(\.rawValue).contains(type.identifier))
        #expect(!type.conforms(to: .text) && !type.conforms(to: .url))
        let id = UUID()
        #expect(RailReorderDelegate.provider(for: id).registeredTypeIdentifiers == [type.identifier])
    }

    @Test("El riel dice si el proyecto está fijado o sin actividad")
    func railAccessibility() {
        let pinned = Project(name: "ecommerce", path: "/e", pinned: true)
        #expect(RailItem.accessibilityText(project: pinned, activity: Activity(pending: 1)) == "ecommerce, fijado, una sesión te espera")
        let idle = Project(name: "bevo", path: "/b")
        #expect(RailItem.accessibilityText(project: idle, activity: Activity(), isActive: false) == "bevo, sin actividad hoy")
        #expect(RailItem.accessibilityText(project: idle, activity: Activity()) == "bevo")
    }
}
