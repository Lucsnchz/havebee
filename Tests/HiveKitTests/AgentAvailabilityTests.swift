import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Agentes instalados")
struct AgentAvailabilityTests {
    @Test("Marca como no instalados los agentes que no están en el PATH")
    func missingAgents() async {
        let world = TestWorld()
        world.processes.installed = ["claude"]
        let availability = AgentAvailability(environment: world.environment)
        // Mientras no se revisó, se los da por instalados.
        #expect(availability.isInstalled(.codex))
        #expect(!availability.checked)
        await availability.refresh().value
        #expect(availability.checked)
        #expect(availability.isInstalled(.claude))
        #expect(!availability.isInstalled(.codex))
        #expect(!availability.isInstalled(.gemini))
        // La terminal usa tu shell: siempre está.
        #expect(availability.isInstalled(.shell))
        #expect(availability.missing == [.codex, .gemini])
    }

    @Test("Al volver a revisar ve los que se instalaron después")
    func refreshSeesNewInstalls() async {
        let world = TestWorld()
        world.processes.installed = []
        let availability = AgentAvailability(environment: world.environment)
        await availability.refresh().value
        #expect(availability.missing == [.claude, .codex, .gemini])
        world.processes.installed = ["claude", "codex", "gemini"]
        await availability.refresh().value
        #expect(availability.missing.isEmpty)
    }

    @Test("Hay una por store, y se revisa sola la primera vez")
    func sharedPerStore() async {
        let world = TestWorld()
        world.processes.installed = ["codex"]
        let store = world.makeStore()
        let availability = AgentAvailability.shared(for: store)
        #expect(AgentAvailability.shared(for: store) === availability)
        #expect(await waitUntil { availability.checked })
        #expect(!availability.isInstalled(.claude))
        #expect(availability.isInstalled(.codex))

        let other = TestWorld().makeStore()
        #expect(AgentAvailability.shared(for: other) !== availability)
    }

    @Test("Con el lanzador real busca en el PATH fuera del hilo principal")
    func realStarter() async {
        let dir = TempDir("hive-agents")
        let bin = dir.subdir("bin")
        let claude = bin.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: claude.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let availability = AgentAvailability(processes: TerminalProcessStarter(), path: bin.path)
        await availability.refresh().value
        #expect(availability.isInstalled(.claude))
        #expect(!availability.isInstalled(.codex))
        #expect(!availability.isInstalled(.gemini))
    }
}
