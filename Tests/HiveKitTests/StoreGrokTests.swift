import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: sesiones de Grok")
struct StoreGrokTests {
    typealias Setup = AppStoreSessionTests.Setup

    func event(_ id: UUID, _ name: String, _ payload: JSONValue = [:]) -> HiveEvent {
        HiveEvent(sessionId: id, source: "grok", name: name, payload: payload)
    }

    @Test("Grok arranca con su ID y sus hooks, trabaja, te avisa y se retoma con --resume")
    func grokSession() async throws {
        let s = try await Setup()
        let session = try s.newSession(.grok)
        #expect(session.name == "Grok 1")
        s.store.activate(session.id)
        s.store.select(nil)

        let launch = try #require(s.world.processes.launches.last)
        #expect(launch.executable == "/fake/bin/grok")
        let agentId = try #require(s.store.sessionContext(session.id)?.session.agentSessionId)
        #expect(launch.args == ["--session-id", agentId, "--no-alt-screen"])
        // Los hooks personales quedan instalados en la carpeta de Grok (la del mundo de prueba).
        #expect(FileManager.default.fileExists(atPath: s.world.agents.grokHome.appendingPathComponent("hooks/hive.json").path))

        let rt = try #require(s.store.runtimes[session.id])
        s.store.handle([event(session.id, "UserPromptSubmit", ["sessionId": .string(agentId), "prompt": "Revisá los tests de pagos"])])
        #expect(rt.status == .working)
        #expect(s.store.sessionContext(session.id)?.session.name == "Revisá los tests de pagos")

        s.store.handle([event(session.id, "Stop", ["sessionId": .string(agentId), "lastAssistantMessage": "Los tests de pagos pasan."])])
        #expect(rt.status == .waiting)
        #expect(rt.unseen)
        #expect(s.world.notifier.posts.last?.body == "Los tests de pagos pasan.")
        #expect(s.world.notifier.posts.last?.subtitle == "Revisá los tests de pagos · Tu turno")
        #expect(s.store.sessionContext(session.id)?.session.lastMessage == "Los tests de pagos pasan.")
        #expect(s.store.history.load(session.id).map(\.role) == [.user, .assistant])

        // Grok ya guardó la sesión: al reiniciar se retoma con el mismo ID.
        let saved = s.world.agents.grokHome.appendingPathComponent("sessions/app/\(agentId)")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        s.store.relaunch(session.id)
        #expect(s.world.processes.launches.last?.args == ["--resume", agentId, "--no-alt-screen"])
    }

    @Test("Sin Grok instalado, la sesión queda terminada y no se lanza nada")
    func notInstalled() async throws {
        let s = try await Setup()
        s.world.processes.installed = ["claude", "codex", "gemini"]
        let session = try s.newSession(.grok)
        s.store.activate(session.id)
        #expect(s.world.processes.launches.isEmpty)
        #expect(s.store.runtimes[session.id]?.status == .exited(nil))
    }
}
