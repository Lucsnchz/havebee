import Foundation
import Testing
@testable import HiveCore

@Suite("Trabajo interrumpido: evidencia y lanzamiento")
struct InterruptedWorkTests {
    let since = Date(timeIntervalSince1970: 1_792_152_000.25)

    func line(_ object: JSONValue, at date: Date) throws -> String {
        guard case .object(var values) = object else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        values["timestamp"] = .string(formatter.string(from: date))
        return String(decoding: try JSONSerialization.data(withJSONObject: JSONValue.object(values).anyValue), as: UTF8.self) + "\n"
    }

    @Test("Codex: completar, abortar, una respuesta final o una pregunta pendiente evitan repetir", arguments: [
        JSONValue.object(["type": "event_msg", "payload": ["type": "task_complete"]]),
        JSONValue.object(["type": "event_msg", "payload": ["type": "turn_aborted"]]),
        JSONValue.object(["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "final"]]),
        JSONValue.object(["type": "response_item", "payload": ["type": "function_call", "name": "functions.request_user_input"]])
    ])
    func codexFinished(record: JSONValue) throws {
        let dir = TempDir()
        let pending = PendingAgentWork(launchId: UUID(), since: since)
        let file = dir.write("rollout.jsonl", try line(record, at: since.addingTimeInterval(2)))
        #expect(!InterruptedWork.allowsContinuation(transcript: file, agent: .codex, pending: pending))
    }

    @Test("Una respuesta vieja y una respuesta intermedia no cancelan el turno nuevo")
    func currentTurnOnly() throws {
        let dir = TempDir()
        let pending = PendingAgentWork(launchId: UUID(), since: since)
        let old: JSONValue = ["type": "event_msg", "payload": ["type": "task_complete"]]
        let commentary: JSONValue = ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "commentary"]]
        let start: JSONValue = ["type": "event_msg", "payload": ["type": "task_started"]]
        let file = dir.write("rollout.jsonl", try line(old, at: since.addingTimeInterval(-0.1))
                             + line(start, at: since.addingTimeInterval(1))
                             + line(commentary, at: since.addingTimeInterval(2)))
        #expect(InterruptedWork.allowsContinuation(transcript: file, agent: .codex, pending: pending))
    }

    @Test("Enter sin evidencia de una tarea nueva en Codex no dispara trabajo")
    func codexNeedsNewWork() throws {
        let dir = TempDir()
        let pending = PendingAgentWork(launchId: UUID(), since: since)
        let final: JSONValue = ["type": "event_msg", "payload": ["type": "task_complete"]]
        let file = dir.write("rollout.jsonl", try line(final, at: since.addingTimeInterval(-1)))
        #expect(!InterruptedWork.allowsContinuation(transcript: file, agent: .codex, pending: pending))
    }

    @Test("Un workflow conserva su pendiente aunque el turno que lo lanzó tenga respuesta final")
    func backgroundTurn() throws {
        let dir = TempDir()
        let pending = PendingAgentWork(launchId: UUID(), since: since, backgroundAgents: 1)
        let final: JSONValue = ["type": "assistant", "message": ["stop_reason": "end_turn", "content": []]]
        let file = dir.write("claude.jsonl", try line(final, at: since.addingTimeInterval(-1)))
        #expect(InterruptedWork.allowsContinuation(transcript: file, agent: .claude, pending: pending))
        // Si luego el agente vuelve y termina, no se vuelve a lanzar el workflow.
        dir.write("claude.jsonl", try line(final, at: since.addingTimeInterval(1)))
        #expect(!InterruptedWork.allowsContinuation(transcript: file, agent: .claude, pending: pending))
    }

    @Test("Claude: una pregunta o aprobación de plan pendiente no se contesta sola", arguments: ["AskUserQuestion", "ExitPlanMode"])
    func claudeAsking(tool: String) throws {
        let dir = TempDir()
        let pending = PendingAgentWork(launchId: UUID(), since: since)
        let asking: JSONValue = ["type": "assistant", "message": ["content": [["type": "tool_use", "name": .string(tool)]]]]
        let file = dir.write("claude.jsonl", try line(asking, at: since.addingTimeInterval(2)))
        #expect(!InterruptedWork.allowsContinuation(transcript: file, agent: .claude, pending: pending))
    }

    @Test("No se confunde la generación auxiliar de títulos con el final de la tarea")
    func auxiliaryTitle() throws {
        let dir = TempDir()
        let pending = PendingAgentWork(launchId: UUID(), since: since)
        let title = "Generate a concise, single-line task title of at most 36 characters. Do not answer the request.\nUser prompt:\nArreglá el login"
        let input: JSONValue = ["type": "response_item", "payload": ["type": "message", "role": "user",
                                                                    "content": [["type": "input_text", "text": .string(title)]]]]
        let final: JSONValue = ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "final"]]
        let start: JSONValue = ["type": "event_msg", "payload": ["type": "task_started"]]
        let file = dir.write("rollout.jsonl", try line(start, at: since) + line(input, at: since.addingTimeInterval(1)) + line(final, at: since.addingTimeInterval(2)))
        #expect(InterruptedWork.allowsContinuation(transcript: file, agent: .codex, pending: pending))
    }

    @Test("El mensaje viaja como un único argumento en una conversación reanudada", arguments: [SessionKind.claude, .codex, .grok])
    func resumeArgument(kind: SessionKind) {
        var ctx = LaunchContext(session: Session(name: "Chat", kind: kind, agentSessionId: "saved"),
                                project: Project(name: "P", path: "/repo"), branch: Branch(name: "main", mode: .main),
                                directory: "/repo", path: "/bin", inheritedEnvironment: [:],
                                paths: HivePaths(root: URL(fileURLWithPath: "/Hive")),
                                claudeConversationExists: true, grokConversationExists: true,
                                mcpFile: URL(fileURLWithPath: "/Hive/mcp/scoped.json"), resumeInterruptedWork: true)
        let plan = LaunchPlanner.plan(ctx)
        #expect(plan.continuesInterruptedWork)
        #expect(plan.args.filter { $0 == InterruptedWork.prompt }.count == 1)
        #expect(plan.args.last == InterruptedWork.prompt)
        if kind == .claude {
            #expect(Array(plan.args.suffix(3)) == ["/Hive/mcp/scoped.json", "--", InterruptedWork.prompt])
        }
        #expect(!plan.args.contains("--dangerously-skip-permissions"))
        #expect(!plan.args.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(!plan.args.contains("--always-approve"))
        ctx.resumeInterruptedWork = false
        #expect(!LaunchPlanner.plan(ctx).args.contains(InterruptedWork.prompt))
        ctx.resumeInterruptedWork = true
        ctx.claudeConversationExists = false
        ctx.grokConversationExists = false
        ctx.session.agentSessionId = nil
        #expect(!LaunchPlanner.plan(ctx).continuesInterruptedWork)
    }

    @Test("El checkpoint persiste sin perder fracciones; estados viejos siguen siendo válidos")
    func persistenceCompatibility() throws {
        let dir = TempDir()
        let store = StateStore(file: dir.url.appendingPathComponent("state.json"))
        let pending = PendingAgentWork(launchId: UUID(), since: since, backgroundAgents: 2)
        let session = Session(name: "Chat", kind: .claude, pendingWork: pending)
        let project = Project(name: "P", path: dir.path, branches: [Branch(name: "main", mode: .main, sessions: [session])])
        try store.save(HiveState(projects: [project]))
        guard case .loaded(let state) = store.load() else { Issue.record("No cargó el estado"); return }
        #expect(state.projects[0].allSessions[0].pendingWork == pending)
        let old = Session(name: "Vieja", kind: .claude)
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.pendingWork == nil)
    }

    @Test("Un evento auxiliar o de otro proceso no resuelve ni crea un pendiente")
    func eventOwnership() {
        var session = Session(name: "Chat", kind: .codex)
        let pending = PendingAgentWork(launchId: UUID(), since: since)
        session.pendingWork = pending
        let event = HiveEvent(sessionId: session.id, source: "codex", name: "notify",
                              payload: ["type": "agent-turn-complete", "thread-id": "child"], launchId: pending.launchId)
        #expect(InterruptedWork.reconcile(session, events: [event], isSubagentThread: { _ in true }) == pending)
        session.pendingWork = nil
        #expect(InterruptedWork.reconcile(session, events: [event]) == nil)
    }

    @Test("Los transcripts muestran el mensaje automático como sistema", arguments: [SessionKind.claude, .codex])
    func systemPromptInHistory(kind: SessionKind) throws {
        let dir = TempDir()
        let object: JSONValue = kind == .claude
            ? ["type": "user", "message": ["content": .string(InterruptedWork.prompt)]]
            : ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": .string(InterruptedWork.prompt)]]]]
        let file = dir.write("chat.jsonl", try line(object, at: since))
        #expect(TranscriptReader.read(file, agent: kind).first?.role == .system)
    }

    @Test("Los hooks sobreviven a una caída entre leerlos y aplicarlos; confirmar un lote no borra otro")
    func eventAcknowledgement() throws {
        let dir = TempDir()
        let session = UUID(), launch = UUID()
        let watcher = EventWatcher(directory: dir.url, requiresAcknowledgement: true) { _ in }
        let first = dir.write("first.evt", "\(session)\tclaude\tStop\t\(launch)\n{}")
        let batch = watcher.drain()
        #expect(batch.count == 1)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(watcher.drain().isEmpty)
        let second = dir.write("second.evt", "\(session)\tclaude\tPermissionRequest\t\(launch)\n{}")
        let later = watcher.drain()
        #expect(later.count == 1)
        watcher.acknowledge(batch)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(EventWatcher.pendingEvents(in: dir.url) == later)
        watcher.acknowledge(later)
        #expect(EventWatcher.pendingEvents(in: dir.url).isEmpty)
    }
}
