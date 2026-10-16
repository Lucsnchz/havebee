import AppKit
import Foundation
import HiveCore
import Testing
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

    @Test("El riel dice si el proyecto está fijado o sin actividad")
    func railAccessibility() {
        let pinned = Project(name: "ecommerce", path: "/e", pinned: true)
        #expect(RailItem.accessibilityText(project: pinned, activity: Activity(pending: 1)) == "ecommerce, fijado, una sesión te espera")
        let idle = Project(name: "bevo", path: "/b")
        #expect(RailItem.accessibilityText(project: idle, activity: Activity(), isActive: false) == "bevo, sin actividad hoy")
        #expect(RailItem.accessibilityText(project: idle, activity: Activity()) == "bevo")
    }
}
