import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
private struct RecoverySetup {
    let world = TestWorld()
    let store: AppStore
    let id: UUID

    init(kind: SessionKind = .claude) throws {
        store = world.makeStore()
        let branch = try #require(store.scratchProject?.branches.first)
        store.requestNewSession(branchId: branch.id, kind: kind)
        id = try #require(store.scratchProject?.allSessions.last?.id)
        store.activate(id)
    }

    var session: Session { store.sessionContext(id)!.session }
    var runtime: SessionRuntime { store.runtimes[id]! }

    func working() {
        store.userInput(id, [13][...])
        if session.kind == .claude || session.kind == .grok {
            event("UserPromptSubmit", payload: ["prompt": "Continuá la implementación"])
        }
    }

    func event(_ name: String, payload: JSONValue = [:]) {
        store.handle([HiveEvent(sessionId: id, source: session.kind.rawValue, name: name,
                                payload: payload, launchId: runtime.launchId)])
    }

    @discardableResult
    func transcript(_ content: String = "{}\n") throws -> URL {
        let agentId = try #require(session.agentSessionId)
        return world.dir.write("claude/projects/example/\(agentId).jsonl", content)
    }

    func reopen() -> AppStore {
        let reopened = world.makeStore()
        reopened.activate(id)
        return reopened
    }
}

@MainActor
@Suite("Store: continuar solamente el trabajo interrumpido")
struct StoreRecoveryTests {
    @Test("Una caída conserva el pendiente sin depender de shutdown; abrir dos veces no duplica el prompt")
    func crashRecovery() throws {
        let s = try RecoverySetup()
        try s.transcript()
        s.working()
        let work = try #require(s.session.pendingWork)
        let reopened = s.reopen()
        let launch = try #require(s.world.processes.launches.last)
        #expect(launch.args.contains("--resume"))
        #expect(launch.args.last == InterruptedWork.prompt)
        #expect(reopened.runtimes[s.id]?.status == .working)
        #expect(reopened.sessionContext(s.id)?.session.pendingWork?.launchId != work.launchId)
        reopened.activate(s.id)
        #expect(s.world.processes.launches.count == 2)
        #expect(reopened.history.load(s.id).filter { $0.text == InterruptedWork.marker }.count == 1)
    }

    @Test("Salir conserva un workflow y un cierre tardío no lo borra")
    func backgroundWorkflow() throws {
        let s = try RecoverySetup()
        try s.transcript()
        s.working()
        s.event("Stop", payload: ["last_assistant_message": "El workflow sigue trabajando.",
                                  "background_tasks": [["type": "local_workflow", "status": "running"]]])
        #expect(s.session.pendingWork?.backgroundAgents == 1)
        s.store.shutdown()
        s.store.processExited(s.id, terminal: try #require(s.runtime.terminal), code: 0)
        s.event("Stop") // no pisa el pendiente durante shutdown
        let reopened = s.reopen()
        #expect(s.world.processes.launches.last?.args.last == InterruptedWork.prompt)
        #expect(reopened.runtimes[s.id]?.status == .working)
    }

    @Test("Un workflow largo sin señales no se da por terminado al guardar")
    func quietWorkflowRemainsPending() throws {
        let s = try RecoverySetup()
        try s.transcript()
        s.working()
        s.event("Stop", payload: ["background_tasks": [["type": "local_workflow", "status": "running"]]])
        s.world.advance(BackgroundRule.quiet + 1)
        s.store.tick()
        #expect(s.runtime.status == .waiting)
        #expect(s.session.pendingWork?.backgroundAgents == 1)
        s.store.shutdown()
        _ = s.reopen()
        #expect(s.world.processes.launches.last?.args.last == InterruptedWork.prompt)
    }

    @Test("Terminar, pedir permiso o cortar manualmente cancelan la continuación", arguments: [
        "Stop", "PermissionRequest", "StopFailure", "escape", "ctrl-c", "stop", "archive", "remove", "clean-exit", "silence"
    ])
    func noContinuation(reason: String) throws {
        let s = try RecoverySetup()
        try s.transcript()
        s.working()
        switch reason {
        case "escape":
            s.store.userInput(s.id, [27][...])
            s.event("PreToolUse") // un hook atrasado no deshace la interrupción manual
        case "ctrl-c":
            s.store.userInput(s.id, [3][...])
            s.event("PreToolUse")
        case "stop":
            s.store.stop(s.id)
            s.event("PreToolUse") // no reanima el trabajo mientras el proceso se detiene
        case "archive":
            s.store.archive(s.id)
            s.store.unarchive(s.id)
        case "remove": s.store.stopSessions([s.id])
        case "clean-exit": s.store.processExited(s.id, terminal: try #require(s.runtime.terminal), code: 0)
        case "silence": s.world.advance(10); s.store.tick()
        default: s.event(reason)
        }
        #expect(s.session.pendingWork == nil)
        s.store.shutdown()
        let reopened = s.reopen()
        #expect(reopened.runtimes[s.id]?.status == .idle)
        #expect(!s.world.processes.launches.last!.args.contains(InterruptedWork.prompt))
    }

    @Test("Stop con un servidor de fondo no es un workflow pendiente")
    func serverIsNotWork() throws {
        let s = try RecoverySetup()
        try s.transcript()
        s.working()
        s.event("Stop", payload: ["background_tasks": [["type": "shell", "status": "running"]]])
        #expect(s.session.pendingWork == nil)
        _ = s.reopen()
        #expect(!s.world.processes.launches.last!.args.contains(InterruptedWork.prompt))
    }

    @Test("No se envía nada sin conversación nativa, ni se pierde el pendiente si falta el binario")
    func missingConversationAndBinary() throws {
        let s = try RecoverySetup()
        s.working()
        let originalLaunch = s.session.lastLaunchedAt
        s.world.processes.installed = []
        s.world.advance(100)
        let failed = s.reopen()
        #expect(failed.sessionContext(s.id)?.session.pendingWork != nil)
        #expect(failed.sessionContext(s.id)?.session.lastLaunchedAt == originalLaunch)
        s.world.processes.installed = ["claude"]
        failed.relaunch(s.id)
        #expect(!s.world.processes.launches.last!.args.contains(InterruptedWork.prompt))
        #expect(failed.sessionContext(s.id)?.session.pendingWork == nil)
    }

    @Test("Un hook de fin que quedó sin procesar se aplica antes de abrir la sesión", arguments: ["Stop", "PermissionRequest"])
    func undeliveredEvent(name: String) throws {
        let s = try RecoverySetup()
        try s.transcript()
        s.working()
        s.world.dir.write("Hive/events/last.evt", "\(s.id.uuidString)\tclaude\t\(name)\t\(s.runtime.launchId.uuidString)\n{}")
        // El watcher ya lo leyó, pero la app cayó antes de aplicar el lote en el actor principal.
        let watcher = EventWatcher(directory: s.world.paths.eventsDir, requiresAcknowledgement: true) { _ in }
        #expect(watcher.drain().count == 1)
        let reopened = s.reopen()
        #expect(reopened.sessionContext(s.id)?.session.pendingWork == nil)
        #expect(!s.world.processes.launches.last!.args.contains(InterruptedWork.prompt))
        #expect(s.world.notifier.posts.isEmpty)
    }

    @Test("Un hook viejo no cancela la recuperación del proceso correcto")
    func staleEvent() throws {
        let s = try RecoverySetup()
        try s.transcript()
        s.working()
        s.world.dir.write("Hive/events/old.evt", "\(s.id.uuidString)\tclaude\tStop\t\(UUID().uuidString)\n{}")
        _ = s.reopen()
        #expect(s.world.processes.launches.last?.args.last == InterruptedWork.prompt)
    }

    @Test("El final nativo posterior al pendiente impide repetir un turno aunque no haya hook")
    func nativeCompletion() throws {
        let s = try RecoverySetup()
        s.working()
        let stamp = ISO8601DateFormatter().string(from: s.world.now.addingTimeInterval(1))
        try s.transcript("{\"timestamp\":\"\(stamp)\",\"type\":\"assistant\",\"message\":{\"stop_reason\":\"end_turn\",\"content\":[]}}\n")
        _ = s.reopen()
        #expect(!s.world.processes.launches.last!.args.contains(InterruptedWork.prompt))
    }

    @Test("El prompt automático se identifica como sistema y no cambia el nombre del chat")
    func continuationIsNotUserPrompt() throws {
        let s = try RecoverySetup()
        let name = s.session.name
        s.event("UserPromptSubmit", payload: ["prompt": .string(InterruptedWork.prompt)])
        #expect(s.session.name == name)
        #expect(s.store.history.load(s.id).last?.role == .system)
    }

    @Test("Los hooks tardíos no se aplican después de salir; tampoco arrancan nuevas terminales")
    func shutdownIsFinal() throws {
        let s = try RecoverySetup()
        s.store.shutdown()
        s.event("PreToolUse")
        s.store.relaunch(s.id)
        #expect(s.session.pendingWork == nil)
        #expect(s.world.processes.launches.count == 1)
    }

    @Test("Codex retoma el primer turno interrumpido usando el rollout descubierto")
    func discoverCodex() throws {
        let s = try RecoverySetup(kind: .codex)
        let thread = UUID().uuidString.lowercased()
        let stamp = ISO8601DateFormatter().string(from: s.world.now)
        let cwd = s.world.home.path
        let meta: JSONValue = ["type": "session_meta", "payload": ["id": .string(thread), "cwd": .string(cwd),
                                                                  "timestamp": .string(stamp), "source": "cli"]]
        let data = try JSONSerialization.data(withJSONObject: meta.anyValue)
        let day = Calendar.current.dateComponents([.year, .month, .day], from: s.world.now)
        let folder = String(format: "codex/sessions/%04d/%02d/%02d", day.year!, day.month!, day.day!)
        s.world.dir.write("\(folder)/rollout-\(thread).jsonl", String(decoding: data, as: UTF8.self)
                         + "\n{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n")
        s.working()
        #expect(s.session.agentSessionId == nil)
        _ = s.reopen()
        let args = try #require(s.world.processes.launches.last?.args)
        #expect(args.first == "resume")
        #expect(Array(args.suffix(2)) == [thread, InterruptedWork.prompt])
    }

    @Test("Enter en un menú no alcanza para continuar solo con Claude o Grok", arguments: [SessionKind.claude, .grok])
    func enterNeedsConfirmation(kind: SessionKind) throws {
        let s = try RecoverySetup(kind: kind)
        s.store.userInput(s.id, [13][...])
        #expect(s.runtime.status == .working)
        #expect(s.session.pendingWork == nil)
    }

    @Test("Gemini y Terminal no reciben mensajes automáticos", arguments: [SessionKind.gemini, .shell])
    func noReliableHooks(kind: SessionKind) throws {
        let s = try RecoverySetup(kind: kind)
        s.working()
        #expect(s.session.pendingWork == nil)
        _ = s.reopen()
        #expect(!s.world.processes.launches.last!.args.contains(InterruptedWork.prompt))
    }

    @Test("Un pedido nuevo después de Esc vuelve a registrar trabajo pendiente")
    func newPromptAfterInterruption() throws {
        let s = try RecoverySetup()
        s.working()
        s.store.userInput(s.id, [27][...])
        s.event("PreToolUse")
        #expect(s.session.pendingWork == nil)
        s.working()
        #expect(s.session.pendingWork != nil)
    }

    @Test("Reiniciar antes de confirmar HEAD no manda la tarea a otra rama")
    func recoveryWaitsForCorrectBranch() async throws {
        let world = TestWorld(), repo = GitRepo()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let branch = try #require(store.repoProjects.first?.branches.first)
        store.requestNewSession(branchId: branch.id, kind: .claude)
        let id = try #require(store.repoProjects.first?.allSessions.last?.id)
        store.activate(id)
        let session = try #require(store.sessionContext(id)?.session)
        let agent = try #require(session.agentSessionId)
        world.dir.write("claude/projects/example/\(agent).jsonl", "{}\n")
        store.handle([HiveEvent(sessionId: id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Arreglá el login"])])
        store.shutdown()
        _ = repo.sh("git checkout -q -b otra")
        let reopened = world.makeStore()
        reopened.relaunch(id)
        #expect(world.processes.launches.count == 1)
        await reopened.confirmSavedHeads()
        reopened.activate(id)
        #expect(world.processes.launches.count == 1)
        #expect(reopened.sessionContext(id)?.session.pendingWork != nil)
    }
}
