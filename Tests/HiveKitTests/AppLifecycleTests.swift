import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Salir de Hive")
struct AppLifecycleTests {
    /// Un store con una sesión de Claude en «Terminales», lanzada con procesos falsos.
    @MainActor
    final class QuitFixture {
        let world = TestWorld()
        let store: AppStore
        let id: UUID

        init() throws {
            store = world.makeStore()
            let branch = try #require(store.scratchProject?.branches.first)
            store.requestNewSession(branchId: branch.id, kind: .claude)
            id = try #require(store.scratchProject?.branches.first?.sessions.last?.id)
            store.activate(id)
        }
    }

    @Test("Sin nada corriendo sale sin preguntar")
    func nothingRunning() throws {
        let f = try QuitFixture()
        var asked: [String] = []
        let reply = HiveAppDelegate.terminateReply(store: f.store) { asked.append($0); return false }
        #expect(reply == .terminateNow)
        #expect(asked.isEmpty)
    }

    @Test("Con una sesión trabajando pregunta, y Cancelar no corta nada")
    func cancel() throws {
        let f = try QuitFixture()
        f.store.userInput(f.id, [13])
        let rt = try #require(f.store.runtimes[f.id])
        #expect(rt.status == .working)
        var asked: [String] = []
        let reply = HiveAppDelegate.terminateReply(store: f.store) { asked.append($0); return false }
        #expect(reply == .terminateCancel)
        #expect(asked == ["Hay una sesión trabajando"])
        #expect(rt.status == .working)
        #expect(rt.terminal != nil)
    }

    @Test("Si confirmás, sale")
    func confirm() throws {
        let f = try QuitFixture()
        f.store.userInput(f.id, [13])
        var asked = 0
        let reply = HiveAppDelegate.terminateReply(store: f.store) { _ in asked += 1; return true }
        #expect(reply == .terminateNow)
        #expect(asked == 1)
        // Antes de salir se guardó el estado.
        #expect(FileManager.default.fileExists(atPath: f.world.paths.stateFile.path))
    }
}
