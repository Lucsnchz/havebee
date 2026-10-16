import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: ciclo de vida, persistencia y diálogos")
struct StoreLifecycleTests {
    @Test("Cola de alertas: de a una, en orden, sin repetidas")
    func alertQueue() throws {
        let world = TestWorld()
        let store = world.makeStore()
        #expect(store.alert == nil)
        store.alert = AppAlert(title: "Uno", message: "a")
        store.alert = AppAlert(title: "Dos", message: "b", actionTitle: "Borrar igual", isDestructive: true)
        store.alert = AppAlert(title: "Uno", message: "a") // repetida: no se encola de nuevo
        #expect(store.alerts.map(\.title) == ["Uno", "Dos"])
        #expect(store.alert?.title == "Uno") // la segunda no pisa a la que se está mostrando
        store.alert = nil
        #expect(store.alert?.title == "Dos")
        #expect(store.alert?.isDestructive == true)
        #expect(store.alert?.cancelTitle == nil)

        // Cerrar una alerta puntual no se lleva la siguiente.
        let shown = try #require(store.alert)
        store.alert = AppAlert(title: "Tres", message: "c")
        store.dismissAlert(shown.id)
        store.dismissAlert(shown.id) // dos veces: no pasa nada
        #expect(store.alerts.map(\.title) == ["Tres"])
        store.alert = nil
        store.alert = nil
        #expect(store.alert == nil)
    }

    @Test("Una acción que abre otra alerta la encola detrás")
    func actionOpensAnotherAlert() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let folder = TempDir()
        try "x".write(toFile: folder.path + "/archivo.txt", atomically: true, encoding: .utf8)
        await store.addProject(at: folder.path)
        let alert = try #require(store.alert)
        #expect(alert.message.hasPrefix("“\(folder.url.lastPathComponent)” no es un repo de git. ¿Querés inicializarlo y agregarlo a Hive?"))
        #expect(alert.message.hasSuffix("\n\n\(folder.path)"))
        #expect(!alert.isDestructive)
        store.alert = AppAlert(title: "Otra", message: "en cola")
        alert.action?()
        #expect(await waitUntil { store.repoProjects.count == 1 })
        store.dismissAlert(alert.id)
        #expect(store.alert?.title == "Otra")
    }

    @Test("Con state.json ilegible no se pisa y se avisa")
    func unreadableStateIsNotOverwritten() async throws {
        let world = TestWorld()
        try FileManager.default.createDirectory(at: world.paths.root, withIntermediateDirectories: true)
        let original = "{\"projects\": [], \"expanded\": []}"
        try original.write(to: world.paths.stateFile, atomically: true, encoding: .utf8)
        let path = world.paths.stateFile.path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        let store = world.makeStore()
        #expect(store.alert?.title == "No pude leer tu estado")
        #expect(store.alert?.message.contains(path) == true)
        #expect(store.alert?.actionTitle == "Mostrar en Finder")
        #expect(store.alert?.isDestructive == false)
        let repo = GitRepo()
        await store.addProject(at: repo.path)
        store.saveNow()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
    }

    @Test("Con state.json roto avisa dónde quedó la copia")
    func corruptedStateWarns() throws {
        let world = TestWorld()
        try FileManager.default.createDirectory(at: world.paths.root, withIntermediateDirectories: true)
        try "{roto".write(to: world.paths.stateFile, atomically: true, encoding: .utf8)
        let store = world.makeStore()
        let alert = try #require(store.alert)
        #expect(alert.title == "Tu estado anterior estaba dañado")
        let backup = try #require(FileManager.default.contentsOfDirectory(atPath: world.paths.root.path).first { $0.hasSuffix(".bak.json") })
        #expect(alert.message.contains(world.paths.root.appendingPathComponent(backup).path))
        #expect(alert.actionTitle == "Mostrar en Finder")
    }

    @Test("Si no se puede guardar, avisa una sola vez")
    func saveErrorWarnsOnce() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        // Donde va el estado hay un archivo en lugar de una carpeta: no se puede escribir.
        try FileManager.default.createDirectory(at: world.paths.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: world.paths.root, atomically: true, encoding: .utf8)
        store.setExpanded(UUID(), true)
        store.setExpanded(UUID(), true)
        #expect(store.alerts.map(\.title) == ["No pude guardar tu estado"])
    }

    @Test("Guardar con espera agrupa los cambios y shutdown guarda lo pendiente")
    func delayedSaveAndShutdown() async throws {
        let world = TestWorld()
        var environment = world.environment
        environment.saveDelay = 30
        let store = AppStore(environment: environment)
        let repo = GitRepo()
        await store.addProject(at: repo.path)
        #expect(!FileManager.default.fileExists(atPath: world.paths.stateFile.path)) // todavía no
        store.shutdown()
        let saved = try #require(world.makeStore().repoProjects.first)
        #expect(saved.path == repo.path)
    }

    @Test("start() instala el puente, prepara los avisos y un .evt real cambia el estado")
    func startInstallsBridge() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.allSessions.first)
        store.activate(session.id)
        store.select(nil)

        store.start()
        defer { store.shutdown() }
        #expect(store.alert == nil)
        #expect(world.notifier.setupCalls == 1)
        #expect(FileManager.default.isExecutableFile(atPath: world.paths.eventBin.path))
        #expect(FileManager.default.fileExists(atPath: world.paths.claudeSettings.path))

        let event = "\(session.id.uuidString)\tclaude\tUserPromptSubmit\n{\"prompt\": \"Hacé el deploy\"}"
        try event.write(to: world.paths.eventsDir.appendingPathComponent("1.evt"), atomically: true, encoding: .utf8)
        #expect(await waitUntil { store.runtimes[session.id]?.status == .working })
        #expect(store.sessionContext(session.id)?.session.name == "Hacé el deploy")
    }

    @Test("Si no se puede instalar el puente de eventos, avisa")
    func bridgeFailureWarns() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        try FileManager.default.createDirectory(at: world.paths.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: world.paths.root, atomically: true, encoding: .utf8)
        store.start()
        defer { store.shutdown() }
        #expect(store.alerts.map(\.title).contains("No pude instalar el puente de eventos de los agentes"))
        #expect(store.alerts.first { $0.title.hasPrefix("No pude instalar") }?.message.hasPrefix("No vas a ver sus estados") == true)
    }

    @Test("Tocar el aviso abre la sesión y expande el árbol")
    func openFromNotification() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.allSessions.first)
        store.select(nil)
        store.setExpanded(project.id, false)
        store.setExpanded(project.branches[0].id, false)
        store.start()
        defer { store.shutdown() }
        world.notifier.onOpen?(session.id)
        #expect(store.selection == .session(session.id))
        #expect(store.isExpanded(project.id) && store.isExpanded(project.branches[0].id))
        #expect(store.runtimes[session.id]?.isRunning == true) // se lanzó al abrirla
    }

    @Test("Volver a la app marca como vista la sesión abierta")
    func appBecameActiveMarksSeen() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.allSessions.first)
        store.activate(session.id)
        store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "Listo."])])
        let rt = try #require(store.runtimes[session.id])
        #expect(rt.unseen) // la app no estaba activa
        #expect(world.badge == "1")
        world.appActive = true
        store.appBecameActive()
        #expect(!rt.unseen)
        #expect(world.badge == nil)
        #expect(world.notifier.cleared.contains(session.id))
    }
}

/// Dibuja una vista fuera de pantalla (como las capturas de ViewRenderTests) y la guarda en PNG si
/// está `HIVE_SNAPSHOTS`. Devuelve cuántos colores distintos tiene (una vista vacía tiene uno).
@MainActor
private func renderNucleoSnapshot(_ view: some View, size: CGSize, name: String, dark: Bool = true) async -> Int {
    _ = NSApplication.shared
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.appearance = appearance
    host.appearance = appearance
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(nanoseconds: 400_000_000)
    host.layoutSubtreeIfNeeded()
    defer { window.close() }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
    host.cacheDisplay(in: host.bounds, to: rep)
    if let dir = ProcessInfo.processInfo.environment["HIVE_SNAPSHOTS"], let png = rep.representation(using: .png, properties: [:]) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    var colors = Set<String>()
    for x in stride(from: 0, to: rep.pixelsWide, by: max(rep.pixelsWide / 40, 1)) {
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(rep.pixelsHigh / 40, 1)) {
            if let c = rep.colorAt(x: x, y: y) { colors.insert(String(format: "%.2f-%.2f-%.2f", c.redComponent, c.greenComponent, c.blueComponent)) }
        }
    }
    return colors.count
}

@MainActor
@Suite("Inicio y bienvenida", .serialized)
struct HomeAndWelcomeTests {
    /// Dos repos con sesiones en distintos estados.
    @MainActor
    private final class Demo {
        let world = TestWorld()
        let shop = GitRepo(name: "tienda")
        let api = GitRepo(name: "api")
        let store: AppStore
        var sessions: [String: Session] = [:]

        init() async throws {
            store = world.makeStore()
            await store.addProject(at: shop.path)
            await store.addProject(at: api.path)
            let shop = try #require(store.repoProjects.first), api = try #require(store.repoProjects.last)
            func open(_ branch: Branch, _ kind: SessionKind, _ key: String) throws {
                store.requestNewSession(branchId: branch.id, kind: kind)
                sessions[key] = try #require(store.branchContext(branch.id)?.branch.sessions.last)
                store.activate(sessions[key]!.id)
            }
            try open(shop.branches[0], .claude, "permiso")
            try open(shop.branches[0], .codex, "turno")
            try open(api.branches[0], .claude, "trabaja")
            try open(api.branches[0], .shell, "terminal")
            store.select(nil)
            for (key, prompt) in [("permiso", "Agregá validación de stock al checkout"), ("trabaja", "Migrá la API de pagos a la v2")] {
                store.handle([HiveEvent(sessionId: sessions[key]!.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": .string(prompt)])])
            }
            store.handle([
                HiveEvent(sessionId: sessions["permiso"]!.id, source: "claude", name: "Notification",
                          payload: ["notification_type": "permission_prompt", "message": "Claude necesita permiso para usar Bash"]),
                HiveEvent(sessionId: sessions["turno"]!.id, source: "codex", name: "notify",
                          payload: ["type": "agent-turn-complete", "thread-id": "t-1", "input-messages": ["Revisá los tests de pagos"],
                                    "last-assistant-message": "Listo: los tests de pagos pasan y agregué dos casos nuevos."]),
            ])
        }
    }

    @Test("Los grupos del Inicio: permiso, tu turno, trabajando y recientes, sin grupos vacíos")
    func groups() async throws {
        let demo = try await Demo()
        let store = demo.store
        let groups = HomeSessionGroups.build(projects: store.projects, status: { store.runtimes[$0]?.status })
        #expect(groups.map(\.title) == ["Necesitan permiso", "Tu turno", "Trabajando", "Recientes"])
        #expect(groups[0].items.map(\.id) == [demo.sessions["permiso"]!.id])
        #expect(groups[1].items.map(\.id) == [demo.sessions["turno"]!.id])
        #expect(groups[2].items.map(\.id) == [demo.sessions["trabaja"]!.id])
        #expect(groups[3].items.map(\.id) == [demo.sessions["terminal"]!.id])
        #expect(groups[0].items[0].project.name == "tienda")

        // Recientes: como mucho 6, primero la más reciente, sin las archivadas.
        let project = try #require(store.repoProjects.first)
        for _ in 0..<8 {
            demo.world.advance(60)
            store.requestNewSession(branchId: project.branches[0].id, kind: .shell)
        }
        let newest = try #require(store.project(project.id)?.branches[0].sessions.last)
        store.archive(newest.id)
        let regrouped = HomeSessionGroups.build(projects: store.projects, status: { store.runtimes[$0]?.status })
        let recent = try #require(regrouped.last)
        #expect(recent.items.count == HomeSessionGroups.recentLimit)
        #expect(!recent.items.contains { $0.id == newest.id })
        #expect(recent.items.map(\.session.recency) == recent.items.map(\.session.recency).sorted(by: >))
        #expect(HomeSessionGroups.build(projects: [], status: { _ in nil }).isEmpty)
    }

    @Test("La línea de resumen del Inicio arranca en mayúscula y concuerda", arguments: [
        (0, 0, "Nada te espera por ahora."),
        (1, 0, "Una sesión te espera."),
        (3, 0, "3 sesiones te esperan."),
        (0, 1, "Una sesión está trabajando."),
        (0, 2, "2 sesiones están trabajando."),
        (2, 1, "2 sesiones te esperan y una está trabajando."),
        (1, 4, "Una sesión te espera y 4 están trabajando."),
    ])
    func summary(waiting: Int, working: Int, expected: String) {
        #expect(HomeSessionGroups.summary(waiting: waiting, working: working) == expected)
    }

    @Test("Sin selección se ve el Inicio en las dos vistas; sin proyectos, la bienvenida")
    func emptyDetail() async throws {
        let demo = try await Demo()
        #expect(await renderNucleoSnapshot(EmptyDetailView().environment(demo.store), size: CGSize(width: 1100, height: 820), name: "nucleo-01-inicio") > 3)
        #expect(await renderNucleoSnapshot(EmptyDetailView().environment(demo.store), size: CGSize(width: 1100, height: 820),
                                           name: "nucleo-02-inicio-claro", dark: false) > 3)
        let empty = TestWorld().makeStore()
        #expect(await renderNucleoSnapshot(EmptyDetailView().environment(empty), size: CGSize(width: 1000, height: 760), name: "nucleo-03-bienvenida") > 3)
        #expect(await renderNucleoSnapshot(EmptyDetailView().environment(empty), size: CGSize(width: 1000, height: 760),
                                           name: "nucleo-04-bienvenida-clara", dark: false) > 3)
        #expect(await renderNucleoSnapshot(CompactLayout().environment(demo.store), size: CGSize(width: 1180, height: 760), name: "nucleo-05-compacta-inicio") > 3)
    }

    @Test("La cápsula de deshacer")
    func undoToast() async throws {
        let demo = try await Demo()
        demo.store.archive(demo.sessions["turno"]!.id)
        let view = ZStack(alignment: .bottom) {
            Color.black
            UndoToastView().padding(.bottom, 18)
        }
        #expect(await renderNucleoSnapshot(view.environment(demo.store), size: CGSize(width: 700, height: 160), name: "nucleo-06-deshacer") > 3)
        let light = ZStack(alignment: .bottom) {
            Color.white
            UndoToastView().padding(.bottom, 18)
        }
        #expect(await renderNucleoSnapshot(light.environment(demo.store), size: CGSize(width: 700, height: 160),
                                           name: "nucleo-07-deshacer-claro", dark: false) > 3)
        #expect(demo.store.undoAction?.message == "Archivaste “Revisá los tests de pagos”")
    }
}
