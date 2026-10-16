import Foundation
import Testing
@testable import HiveCore

/// Calendario con zona horaria fija: los bordes del día no dependen de la Mac que corre los tests.
private func rielCalendar(_ zone: String = "America/Argentina/Buenos_Aires") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

/// Una fecha con hora local en la zona del calendario.
private func rielDate(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Un proyecto con una sola sesión usada en `used` (o sin sesiones).
private func rielProject(_ name: String, used: Date? = nil, pinned: Bool = false, archived: Bool = false) -> Project {
    let sessions = used.map { [Session(name: "Claude 1", kind: .claude, createdAt: $0, archivedAt: archived ? $0 : nil)] } ?? []
    return Project(name: name, path: "/\(name)", branches: [Branch(name: "main", mode: .main, sessions: sessions)], pinned: pinned)
}

@Suite("Orden de los proyectos (riel, árbol y ⌃⌘N)")
struct ProjectOrderingTests {
    let calendar = rielCalendar()
    /// Jueves 15 de octubre de 2026, 14:00 en Buenos Aires.
    var now: Date { rielDate(calendar, 2026, 10, 15, 14) }
    var today: Date { rielDate(calendar, 2026, 10, 15, 9) }
    var lastWeek: Date { rielDate(calendar, 2026, 10, 8, 18) }

    func ordering(live: Set<UUID> = [], busy: Set<UUID> = [], now: Date? = nil) -> ProjectOrdering {
        ProjectOrdering(now: now ?? self.now, calendar: calendar, liveSessions: live, busyProjects: busy)
    }

    @Test("Los fijados van primero y en el orden manual, estén activos o no")
    func pinnedFirst() {
        let a = rielProject("a", used: today)
        let p1 = rielProject("p1", used: lastWeek, pinned: true)
        let b = rielProject("b", used: lastWeek)
        let p2 = rielProject("p2", used: today, pinned: true)
        let items = ordering().arrange([a, p1, b, p2, .scratch(home: "/h")])
        #expect(items.map(\.project.name) == ["p1", "p2", "a", "b", "Terminales"])
        #expect(items.map(\.group) == [.pinned, .pinned, .active, .idle, .scratch])
    }

    @Test("Los activos siguen el orden manual, no el último uso: no saltan al usarlos")
    func activeKeepManualOrder() {
        let early = rielProject("temprano", used: rielDate(calendar, 2026, 10, 15, 8))
        let idle = rielProject("apagado", used: lastWeek)
        let late = rielProject("recién", used: rielDate(calendar, 2026, 10, 15, 13, 59))
        let items = ordering().arrange([idle, early, late])
        #expect(items.map(\.project.name) == ["temprano", "recién", "apagado"])
        #expect(items.map(\.isActive) == [true, true, false])
    }

    @Test("Una sesión prendida (trabajando o esperándote) cuenta como activa aunque su último uso sea viejo")
    func oldRunningSessionIsActive() throws {
        let running = rielProject("corriendo", used: lastWeek)
        let quiet = rielProject("quieto", used: lastWeek)
        let id = try #require(running.activeSessions.first?.id)
        let items = ordering(live: [id]).arrange([quiet, running])
        #expect(items.map(\.project.name) == ["corriendo", "quieto"])
        #expect(items.first?.group == .active)
        #expect(items.last?.group == .idle)
    }

    @Test("Abrirla no es usarla: un lanzamiento de hoy no la cuenta, escribirle o crearla hoy sí")
    func launchingIsNotUsing() {
        let opened = Project(name: "abierto", path: "/abierto", branches: [Branch(name: "main", mode: .main, sessions: [
            Session(name: "Claude 1", kind: .claude, createdAt: lastWeek, lastLaunchedAt: today, lastActivityAt: lastWeek),
            Session(name: "Gemini 1", kind: .gemini, createdAt: lastWeek, lastLaunchedAt: today),
        ])])
        let written = Project(name: "escrito", path: "/escrito", branches: [Branch(name: "main", mode: .main, sessions: [
            Session(name: "Codex 1", kind: .codex, createdAt: lastWeek, lastLaunchedAt: lastWeek, lastActivityAt: today),
        ])])
        let created = rielProject("creado", used: today)
        let order = ordering()
        #expect(!order.isActive(opened))
        #expect(order.isActive(written))
        #expect(order.isActive(created))
        #expect(order.arrange([opened, written, created]).map(\.project.name) == ["escrito", "creado", "abierto"])
        // El orden de las sesiones por uso reciente (pestañas, ⌘K) sí sigue contando el lanzamiento.
        #expect(opened.activeSessions[1].recency == today)
        #expect(opened.activeSessions[1].lastUsedAt == lastWeek)
    }

    @Test("Un comando corriendo también prende el proyecto")
    func busyProjectIsActive() {
        let server = rielProject("servidor")
        let other = rielProject("otro")
        let items = ordering(busy: [server.id]).arrange([other, server])
        #expect(items.map(\.project.name) == ["servidor", "otro"])
        #expect(ordering().isActive(server) == false)
    }

    @Test("Las sesiones archivadas no cuentan, aunque sean de hoy")
    func archivedDoesNotCount() {
        let project = rielProject("archivado", used: today, archived: true)
        #expect(!ordering().isActive(project))
        #expect(ordering().group(of: project) == .idle)
    }

    @Test("Borde de medianoche: cuenta el día del calendario, con su zona horaria")
    func midnight() {
        // 00:30 del 15 en Buenos Aires (03:30 UTC).
        let justAfterMidnight = rielDate(calendar, 2026, 10, 15, 0, 30)
        let beforeMidnight = rielProject("anoche", used: rielDate(calendar, 2026, 10, 14, 23, 59))
        let afterMidnight = rielProject("hoy", used: rielDate(calendar, 2026, 10, 15, 0, 1))
        let order = ordering(now: justAfterMidnight)
        #expect(!order.isActive(beforeMidnight))
        #expect(order.isActive(afterMidnight))
        #expect(order.arrange([beforeMidnight, afterMidnight]).map(\.project.name) == ["hoy", "anoche"])

        // Las 23:00 del 14 en Buenos Aires ya son el 15 en UTC: igual es ayer.
        let lateUTC = rielProject("tarde", used: rielDate(rielCalendar("UTC"), 2026, 10, 15, 2))
        #expect(!order.isActive(lateUTC))
        // Con un calendario en UTC, la misma sesión sí es de hoy.
        let utc = ProjectOrdering(now: rielDate(rielCalendar("UTC"), 2026, 10, 15, 3, 30), calendar: rielCalendar("UTC"))
        #expect(utc.isActive(lateUTC))
    }

    @Test("Al cambiar el día, lo de ayer pasa a apagado sin tocar nada")
    func dayChange() {
        let project = rielProject("ayer", used: rielDate(calendar, 2026, 10, 15, 22))
        #expect(ordering(now: rielDate(calendar, 2026, 10, 15, 23, 59)).group(of: project) == .active)
        #expect(ordering(now: rielDate(calendar, 2026, 10, 16, 0, 0)).group(of: project) == .idle)
    }

    @Test("Un fijado sin actividad sigue arriba, pero atenuado")
    func pinnedIdleStaysOnTopDimmed() throws {
        let pinned = rielProject("fijado", used: lastWeek, pinned: true)
        let active = rielProject("activo", used: today)
        let items = ordering().arrange([active, pinned])
        let first = try #require(items.first)
        #expect(first.project.name == "fijado")
        #expect(first.group == .pinned)
        #expect(!first.isActive)
        #expect(items[1].isActive)
    }

    @Test("«Terminales» va siempre al final, aunque esté prendido o diga fijado")
    func scratchLast() throws {
        var scratch = Project.scratch(home: "/h")
        scratch.branches[0].sessions = [Session(name: "Terminal 1", kind: .shell, createdAt: today)]
        scratch.pinned = true
        let pinned = rielProject("fijado", pinned: true)
        let idle = rielProject("apagado", used: lastWeek)
        let items = ordering().arrange([scratch, idle, pinned])
        #expect(items.map(\.project.name) == ["fijado", "apagado", "Terminales"])
        #expect(items.last?.group == .scratch)
        #expect(items.last?.isActive == true)
    }

    @Test("Mover dentro del grupo: se guarda el orden que se ve y nadie cambia de grupo")
    func moveWithinGroup() {
        let p = rielProject("p", pinned: true)
        let a1 = rielProject("a1", used: today)
        let i1 = rielProject("i1")
        let a2 = rielProject("a2", used: today)
        let a3 = rielProject("a3", used: today)
        let i2 = rielProject("i2")
        let manual = [a1, i1, p, a2, i2, a3, .scratch(home: "/h")]
        let order = ordering()
        #expect(order.arrange(manual).map(\.project.name) == ["p", "a1", "a2", "a3", "i1", "i2", "Terminales"])

        // a3 (tercero de los activos) al principio de los activos.
        let moved = order.moving(manual, in: .active, fromOffsets: [2], toOffset: 0)
        #expect(moved.map(\.name) == ["p", "a3", "a1", "a2", "i1", "i2", "Terminales"])
        #expect(order.arrange(moved).map(\.project.name) == moved.map(\.name))

        // Llevarlo «más allá» del grupo lo deja último del grupo, no entre los apagados.
        let toEnd = order.moving(manual, in: .active, fromOffsets: [0], toOffset: 99)
        #expect(toEnd.map(\.name) == ["p", "a2", "a3", "a1", "i1", "i2", "Terminales"])
        #expect(order.arrange(toEnd).map(\.group) == [.pinned, .active, .active, .active, .idle, .idle, .scratch])

        // Los apagados se mueven entre ellos.
        let idleMoved = order.moving(manual, in: .idle, fromOffsets: [1], toOffset: 0)
        #expect(idleMoved.map(\.name) == ["p", "a1", "a2", "a3", "i2", "i1", "Terminales"])
    }

    @Test("Subir y Bajar: dentro del grupo y sin pasar los bordes")
    func moveByOne() throws {
        let p1 = rielProject("p1", pinned: true)
        let p2 = rielProject("p2", pinned: true)
        let a = rielProject("a", used: today)
        let i = rielProject("i")
        let manual = [a, p1, i, p2]
        let order = ordering()
        #expect(try #require(order.position(of: p2.id, in: manual)) == (1, 2))
        #expect(try #require(order.position(of: a.id, in: manual)) == (0, 1))
        #expect(order.position(of: UUID(), in: manual) == nil)

        let up = try #require(order.moving(manual, id: p2.id, by: -1))
        #expect(up.map(\.name) == ["p2", "p1", "a", "i"])
        #expect(order.moving(manual, id: p2.id, by: 1) == nil) // último de los fijados
        #expect(order.moving(manual, id: a.id, by: -1) == nil) // no sube a los fijados
        #expect(order.moving(manual, id: i.id, by: 1) == nil)
        #expect(order.moving(manual, id: UUID(), by: 1) == nil)
    }

    @Test("Arrastrar uno sobre otro (el riel): toma su lugar, solo dentro del grupo")
    func dragOnto() throws {
        let p = rielProject("p", pinned: true)
        let a1 = rielProject("a1", used: today)
        let a2 = rielProject("a2", used: today)
        let a3 = rielProject("a3", used: today)
        let i = rielProject("i")
        let scratch = Project.scratch(home: "/h")
        let manual = [i, a1, p, a2, a3, scratch]
        let order = ordering()
        // De arriba hacia abajo queda abajo del otro; de abajo hacia arriba, arriba.
        #expect(try #require(order.moving(manual, dragging: a1.id, onto: a3.id)).map(\.name) == ["p", "a2", "a3", "a1", "i", "Terminales"])
        #expect(try #require(order.moving(manual, dragging: a3.id, onto: a1.id)).map(\.name) == ["p", "a3", "a1", "a2", "i", "Terminales"])
        #expect(try #require(order.moving(manual, dragging: a2.id, onto: a3.id)).map(\.name) == ["p", "a1", "a3", "a2", "i", "Terminales"])
        // Entre grupos, sobre sí mismo, con «Terminales» o con un id desconocido: nada.
        #expect(order.moving(manual, dragging: a1.id, onto: p.id) == nil)
        #expect(order.moving(manual, dragging: i.id, onto: a1.id) == nil)
        #expect(order.moving(manual, dragging: a1.id, onto: a1.id) == nil)
        #expect(order.moving(manual, dragging: scratch.id, onto: i.id) == nil)
        #expect(order.moving(manual, dragging: UUID(), onto: a1.id) == nil)

        // Lo mismo decide si el riel deja soltarlo (si no, el puntero lo muestra prohibido).
        #expect(order.canDrag(a1.id, onto: a3.id, in: manual))
        #expect(order.canDrag(a1.id, onto: a1.id, in: manual)) // sobre sí mismo, después de moverse
        #expect(!order.canDrag(a1.id, onto: p.id, in: manual))
        #expect(!order.canDrag(i.id, onto: a1.id, in: manual))
        #expect(!order.canDrag(scratch.id, onto: scratch.id, in: manual))
        #expect(!order.canDrag(a1.id, onto: UUID(), in: manual))
    }

    @Test("Fijar lo deja último de los fijados; desfijarlo, primero de su grupo")
    func pinAndUnpin() throws {
        let p1 = rielProject("p1", pinned: true)
        let a1 = rielProject("a1", used: today)
        let a2 = rielProject("a2", used: today)
        let i1 = rielProject("i1")
        let i2 = rielProject("i2")
        let manual = [i1, a1, p1, i2, a2, .scratch(home: "/h")]
        let order = ordering()

        let pinnedIdle = order.pinning(manual, id: i2.id, pinned: true)
        #expect(pinnedIdle.map(\.name) == ["p1", "i2", "a1", "a2", "i1", "Terminales"])
        #expect(pinnedIdle.first { $0.id == i2.id }?.pinned == true)
        #expect(order.arrange(pinnedIdle).map(\.project.name) == pinnedIdle.map(\.name))

        let unpinned = order.pinning(pinnedIdle, id: p1.id, pinned: false)
        #expect(unpinned.map(\.name) == ["i2", "p1", "a1", "a2", "i1", "Terminales"])
        // p1 no tiene actividad: pasa a ser el primero de los apagados.
        #expect(order.arrange(unpinned).map(\.project.name) == ["i2", "a1", "a2", "p1", "i1", "Terminales"])

        let unpinnedActive = order.pinning(order.pinning(manual, id: a2.id, pinned: true), id: a2.id, pinned: false)
        #expect(order.arrange(unpinnedActive).map(\.project.name) == ["p1", "a2", "a1", "i1", "i2", "Terminales"])

        // «Terminales» no se fija, y un id desconocido no cambia nada.
        let scratchId = try #require(manual.last?.id)
        #expect(order.pinning(manual, id: scratchId, pinned: true) == manual)
        #expect(order.pinning(manual, id: UUID(), pinned: true) == manual)
    }

    @Test("«pinned» se guarda, y un state.json viejo sin el campo carga igual")
    func pinnedPersistence() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let project = Project(name: "fijado", path: "/repo", pinned: true)
        let decoded = try decoder.decode(Project.self, from: encoder.encode(project))
        #expect(decoded.pinned)
        #expect(decoded == project)

        let legacy = """
        {"id": "11111111-1111-1111-1111-111111111111", "name": "viejo", "path": "/repo", "branches": [], "isScratch": false}
        """
        let old = try decoder.decode(Project.self, from: Data(legacy.utf8))
        #expect(!old.pinned)
        #expect(old.name == "viejo")
    }
}
