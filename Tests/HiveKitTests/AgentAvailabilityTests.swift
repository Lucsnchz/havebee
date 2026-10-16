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
        #expect(!availability.isInstalled(.grok))
        // La terminal usa tu shell: siempre está.
        #expect(availability.isInstalled(.shell))
        #expect(availability.missing == [.codex, .gemini, .grok])
    }

    @Test("Al volver a revisar ve los que se instalaron después")
    func refreshSeesNewInstalls() async {
        let world = TestWorld()
        world.processes.installed = []
        let availability = AgentAvailability(environment: world.environment)
        await availability.refresh().value
        #expect(availability.missing == [.claude, .codex, .gemini, .grok])
        world.processes.installed = ["claude", "codex", "gemini", "grok"]
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

    @Test("La primera vez (sin PATH guardado) usa el del shell de login, que ve nvm, volta…")
    func firstLaunchUsesLoginPATH() async {
        let dir = TempDir("hive-agents")
        let fallback = dir.subdir("respaldo")
        let nvm = dir.subdir("nvm-bin")
        FileManager.default.createFile(atPath: nvm.appendingPathComponent("codex").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let calls = AgentAvailabilityCalls()
        let world = TestWorld()
        var environment = world.environment
        environment.processes = TerminalProcessStarter()
        environment.cachedLoginPATH = nil
        environment.inheritedEnvironment["PATH"] = fallback.path
        environment.resolveLoginPATH = { calls.increment(); return nvm.path }
        let availability = AgentAvailability(environment: environment)
        await availability.refresh().value
        #expect(availability.isInstalled(.codex))
        #expect(!availability.isInstalled(.gemini))
        // Se le pregunta al shell una sola vez.
        await availability.refresh().value
        #expect(availability.isInstalled(.codex))
        #expect(calls.count == 1)
    }

    @Test("Con el PATH guardado no le pregunta al shell; si el shell no responde, usa el de respaldo")
    func loginPATHOnlyWhenNeeded() async {
        let calls = AgentAvailabilityCalls()
        let world = TestWorld()
        var environment = world.environment
        environment.resolveLoginPATH = { calls.increment(); return nil }
        let cached = AgentAvailability(environment: environment)
        await cached.refresh().value
        #expect(cached.checked)
        #expect(calls.count == 0)

        environment.cachedLoginPATH = nil
        let fallback = AgentAvailability(environment: environment)
        await fallback.refresh().value
        #expect(fallback.checked)
        #expect(fallback.isInstalled(.claude))
        #expect(calls.count == 1)
    }

    @Test("Antes de mostrar «No instalado» vuelve a revisar (quizás recién se instaló)")
    func recheckBeforeComplaining() async {
        let world = TestWorld()
        world.processes.installed = []
        let availability = AgentAvailability(environment: world.environment)
        await availability.refresh().value
        #expect(!availability.isInstalled(.gemini))
        world.processes.installed = ["gemini"]
        #expect(await availability.recheck(.gemini))
        #expect(!(await availability.recheck(.codex)))
    }

    @Test("Los menús vuelven a revisar solo si la última revisión es vieja")
    func refreshIfStale() async {
        let processes = AgentAvailabilityCountingProcesses()
        let availability = AgentAvailability(processes: processes, path: "/fake/bin")
        await availability.refresh().value
        // Uno por agente (la terminal no se busca).
        let agents = SessionKind.allCases.filter { $0.binary != nil }.count
        #expect(agents == 4)
        #expect(processes.resolves == agents)
        #expect(!availability.isInstalled(.gemini))
        processes.installed = ["gemini"]
        // Recién revisado: no repite.
        #expect(availability.refreshIfStale(maxAge: 60) == nil)
        #expect(processes.resolves == agents)
        // Un minuto después, sí (y ve lo que se instaló).
        await availability.refreshIfStale(maxAge: 60, now: Date().addingTimeInterval(61))?.value
        #expect(processes.resolves == agents * 2)
        #expect(availability.isInstalled(.gemini))
    }
}

/// Lanzador falso que cuenta cuántas veces se buscó un binario.
@MainActor
private final class AgentAvailabilityCountingProcesses: ProcessStarting {
    var installed: Set<String> = []
    private(set) var resolves = 0

    func resolve(_ binary: String, path: String) -> String? {
        resolves += 1
        return installed.contains(binary) ? "/fake/bin/\(binary)" : nil
    }

    func start(_ terminal: HiveTerminalView, executable: String, args: [String], environment: [String], directory: String) {}
}

/// Cuenta llamadas desde cualquier hilo (el PATH de login se pide fuera del principal).
private final class AgentAvailabilityCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
