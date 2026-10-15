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
}
