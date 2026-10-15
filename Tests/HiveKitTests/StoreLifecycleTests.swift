import AppKit
import Foundation
import HiveCore
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
