import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
private struct SwitchFixture {
    let world = TestWorld()
    let store: AppStore
    let id: UUID

    init(_ kind: SessionKind = .claude) throws {
        store = world.makeStore()
        let branch = try #require(store.scratchProject?.branches.first)
        store.requestNewSession(branchId: branch.id, kind: kind)
        id = try #require(store.scratchProject?.allSessions.last?.id)
        store.activate(id)
    }

    func event(_ source: String, _ name: String, _ payload: JSONValue) {
        world.advance(1)
        store.handle([HiveEvent(sessionId: id, source: source, name: name, payload: payload,
                                launchId: store.runtimes[id]?.launchId)])
    }

    func switchTo(_ kind: SessionKind) async throws {
        store.requestSwitchAgent(id, to: kind)
        try #require(await waitUntil { store.sessionContext(id)?.session.kind == kind && store.runtimes[id]?.terminal != nil })
    }
}

@MainActor
@Suite("Store: cambiar de IA con historial")
struct StoreAgentSwitchTests {
    @Test("Con procesos reales, termina el anterior antes de lanzar el nuevo y evita cambios duplicados")
    func realProcessHandoff() async throws {
        let world = TestWorld()
        let processes = HandoffProcesses()
        var environment = world.environment
        environment.processes = processes
        environment.launchesInBackground = true
        let store = AppStore(environment: environment)
        defer { store.shutdown() }
        let branch = try #require(store.scratchProject?.branches.first)
        store.requestNewSession(branchId: branch.id, kind: .claude)
        let id = try #require(store.scratchProject?.allSessions.first?.id)
        store.activate(id)
        try #require(await waitUntil { store.runtimes[id]?.terminal?.isProcessRunning == true })
        let previous = try #require(store.runtimes[id]?.terminal)
        store.handle([HiveEvent(sessionId: id, source: "claude", name: "Stop",
                               payload: ["last_assistant_message": "Historial del proceso anterior"],
                               launchId: store.runtimes[id]?.launchId)])
        store.requestSwitchAgent(id, to: .codex)
        store.requestSwitchAgent(id, to: .codex)
        try #require(await waitUntil { store.runtimes[id]?.kind == .codex && store.runtimes[id]?.terminal?.isProcessRunning == true })
        #expect(!previous.isProcessRunning)
        #expect(!processes.overlapped)
        #expect(processes.terminals.count == 2)
        let current = try #require(store.runtimes[id]?.terminal)
        #expect(await waitUntil { current.fullText().contains("Agente listo") })
        #expect(current.fullText().contains("Historial del proceso anterior"))
    }

    @Test("Claude → Codex → Claude conserva la pestaña, los mensajes, /clear y sus autores")
    func roundTrip() async throws {
        let f = try SwitchFixture()
        f.event("claude", "UserPromptSubmit", ["prompt": "Agregá validación de stock"])
        f.event("claude", "Stop", ["last_assistant_message": "Validación implementada por Claude"])
        f.event("claude", "SessionStart", ["session_id": "claude-after-clear", "source": "clear"])
        let original = try #require(f.store.sessionContext(f.id)?.session)
        let oldLaunch = try #require(f.store.runtimes[f.id]?.launchId)
        // El traspaso explícito funciona incluso si el aviso de historial normal está apagado.
        f.world.settings.historyHint = false
        f.world.settings.claudeInline = false
        try await f.switchTo(.codex)
        let codex = try #require(f.store.sessionContext(f.id)?.session)
        let firstArgs = try #require(f.world.processes.launches.last?.args)
        #expect(codex.id == original.id && codex.name == original.name && codex.createdAt == original.createdAt)
        #expect(codex.agentSessionId == nil && codex.handoffFrom == .claude)
        #expect(f.store.scratchProject?.allSessions.count == 1)
        #expect(f.store.selection == .session(f.id))
        #expect(!firstArgs.contains("resume") && !firstArgs.contains("claude-after-clear"))
        #expect(firstArgs.contains { $0.contains("developer_instructions=") && $0.contains("Validación implementada por Claude") && $0.contains("/clear") })
        let codexTerminal = try #require(f.store.runtimes[f.id]?.terminal)
        codexTerminal.receive(Array("\u{1B}[2J\u{1B}[3J\u{1B}[HCodex listo".utf8)[...])
        #expect(codexTerminal.fullText().contains("Validación implementada por Claude"))
        #expect(codexTerminal.fullText().contains("/clear") && codexTerminal.fullText().contains("Cambio de IA"))
        #expect(f.world.processes.launches.last?.environment["HIVE_HISTORY_FILE"] == f.store.history.markdownURL(f.id).path)

        f.event("codex", "notify", ["type": "agent-turn-complete", "thread-id": "codex-thread",
                                    "input-messages": ["Revisá y seguí"], "last-assistant-message": "Codex revisó los tests"])
        try await f.switchTo(.claude)
        let returned = try #require(f.store.sessionContext(f.id)?.session)
        let lastArgs = try #require(f.world.processes.launches.last?.args)
        #expect(returned.handoffFrom == .codex)
        #expect(returned.agentSessionId != "codex-thread" && returned.agentSessionId != "claude-after-clear")
        #expect(lastArgs.contains("--append-system-prompt"))
        #expect(lastArgs.contains { $0.contains("Codex revisó los tests") && $0.contains("Validación implementada por Claude") })
        let claudeTerminal = try #require(f.store.runtimes[f.id]?.terminal)
        #expect(claudeTerminal.fullText().contains("Validación implementada por Claude"))
        #expect(claudeTerminal.fullText().contains("Codex revisó los tests"))
        #expect(f.world.processes.launches.last?.environment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] == "1")
        let entries = f.store.history.load(f.id)
        #expect(entries.filter { $0.role == .assistant }.map(\.agent) == [.claude, .codex])
        #expect(entries.filter { $0.text.hasPrefix(AgentHandoff.markerPrefix) }.count == 2)
        let markdown = try String(contentsOf: f.store.history.markdownURL(f.id), encoding: .utf8)
        #expect(markdown.contains("## Claude Code") && markdown.contains("## Codex") && markdown.contains("/clear"))

        // Un hook de la primera ejecución de Claude no puede modificar la nueva.
        let count = entries.count
        f.store.handle([HiveEvent(sessionId: f.id, source: "claude", name: "Stop",
                                 payload: ["last_assistant_message": "respuesta vieja"], launchId: oldLaunch)])
        f.store.handle([HiveEvent(sessionId: f.id, source: "codex", name: "notify",
                                 payload: ["type": "agent-turn-complete", "last-assistant-message": "otro aviso viejo"])])
        #expect(f.store.history.load(f.id).count == count)
        #expect(f.store.runtimes[f.id]?.status == .idle)
        f.event("claude", "Stop", ["last_assistant_message": "Sigo con todo el contexto"])
        #expect(f.store.history.load(f.id).last?.text == "Sigo con todo el contexto")

        f.store.saveNow()
        let reopened = f.world.makeStore()
        #expect(reopened.sessionContext(f.id)?.session.handoffFrom == .codex)
        reopened.activate(f.id)
        #expect(f.world.processes.launches.last?.args.contains { $0.contains("Codex revisó los tests") } == true)
        let restored = try #require(reopened.runtimes[f.id]?.terminal)
        #expect(restored.fullText().contains("Validación implementada por Claude"))
        #expect(restored.fullText().contains("Codex revisó los tests"))
        // Ir a otra pestaña y volver conserva la misma terminal, sin inyectar otra copia.
        let branch = try #require(reopened.scratchProject?.branches.first)
        reopened.requestNewSession(branchId: branch.id, kind: .shell)
        reopened.select(.session(f.id))
        reopened.activate(f.id)
        #expect(reopened.runtimes[f.id]?.terminal === restored)
        #expect(restored.fullText().components(separatedBy: "Validación implementada por Claude").count == 2)
    }

    @Test("Sin el agente instalado o con el mismo agente, no corta la sesión")
    func missingAndSameAgent() throws {
        let f = try SwitchFixture()
        let terminal = f.store.runtimes[f.id]?.terminal
        f.store.requestSwitchAgent(f.id, to: .claude)
        #expect(f.world.processes.launches.count == 1)
        f.world.processes.installed.remove("codex")
        f.store.requestSwitchAgent(f.id, to: .codex)
        #expect(f.store.alert?.title == "Codex no está instalado")
        #expect(f.store.runtimes[f.id]?.terminal === terminal)
        #expect(f.store.runtimes[f.id]?.isSwitchingAgent == false)
        #expect(f.store.sessionContext(f.id)?.session.kind == .claude)
    }

    @Test("Si está trabajando pide confirmar antes del traspaso")
    func busy() async throws {
        let f = try SwitchFixture()
        f.store.userInput(f.id, [13])
        f.store.requestSwitchAgent(f.id, to: .codex)
        let alert = try #require(f.store.alert)
        #expect(alert.actionTitle == "Cambiar de IA igual")
        #expect(f.store.sessionContext(f.id)?.session.kind == .claude)
        #expect(f.world.processes.launches.count == 1)
        alert.action?()
        #expect(await waitUntil { f.store.sessionContext(f.id)?.session.kind == .codex })
    }

    @Test("Archivar durante el traspaso cancela el lanzamiento pendiente")
    func archiveCancels() async throws {
        let f = try SwitchFixture()
        f.store.requestSwitchAgent(f.id, to: .codex)
        f.store.archive(f.id)
        // Barrera: un nuevo cambio en otra sesión termina después de que el cancelado pudo reanudarse.
        let branch = try #require(f.store.scratchProject?.branches.first)
        f.store.requestNewSession(branchId: branch.id, kind: .claude)
        let other = try #require(f.store.scratchProject?.allSessions.last)
        f.store.activate(other.id)
        f.store.requestSwitchAgent(other.id, to: .codex)
        #expect(await waitUntil { f.store.sessionContext(other.id)?.session.kind == .codex })
        #expect(f.store.sessionContext(f.id)?.session.kind == .claude)
        #expect(f.store.sessionContext(f.id)?.session.isArchived == true)
        #expect(f.store.runtimes[f.id]?.terminal == nil)
        #expect(f.world.processes.launches.count == 3)
    }

    @Test("Si el historial no se puede guardar, no cambia de IA")
    func writeFailure() async throws {
        let f = try SwitchFixture()
        try FileManager.default.removeItem(at: f.world.paths.historyDir)
        try Data("no es una carpeta".utf8).write(to: f.world.paths.historyDir)
        f.store.requestSwitchAgent(f.id, to: .codex)
        #expect(await waitUntil { f.store.alert != nil })
        #expect(f.store.alert?.title == "No pude guardar el contexto para cambiar de IA")
        #expect(f.store.sessionContext(f.id)?.session.kind == .claude)
        #expect(f.world.processes.launches.count == 1)
    }
}

/// Usa un proceso local interactivo en lugar de consumir una cuenta de IA.
@MainActor
private final class HandoffProcesses: ProcessStarting {
    var terminals: [HiveTerminalView] = []
    var overlapped = false

    func resolve(_ binary: String, path: String) -> String? { "/bin/sh" }

    func start(_ terminal: HiveTerminalView, executable: String, args: [String], environment: [String], directory: String) {
        overlapped = overlapped || terminals.contains { $0.isProcessRunning }
        terminals.append(terminal)
        let script = "printf '\\033[2J\\033[3J\\033[HAgente listo\\n'; exec /bin/cat"
        terminal.startProcess(executable: executable, args: ["-c", script], environment: environment, currentDirectory: directory)
    }
}
