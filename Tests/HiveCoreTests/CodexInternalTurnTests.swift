import Foundation
import Testing
@testable import HiveCore

@Suite("Codex: resúmenes temporales e historial")
struct CodexInternalTurnTests {
    static let prompt = """
    Write a brief catch-up for a user returning to this task. Return JSON with summary and nullable next_action.

    Summary: explain the broader active goal.
    Next_action: include only an unanswered question for the user. Otherwise null.
    Conversation:
    User: Revisá los permisos
    Assistant: Corregidos y comprobados en local.
    """
    static let reply = #"{"summary":"Permisos corregidos en local.","next_action":null}"#

    @Test("El resumen no cambia ID, pendiente, historial ni notificación", arguments: [nil, "original"] as [String?])
    func ignored(agentId: String?) {
        let event = HiveEvent(sessionId: UUID(), source: "codex", name: "notify", payload: [
            "type": "agent-turn-complete", "thread-id": "temporary-summary",
            "input-messages": [.string(Self.prompt), "<environment_context>injected</environment_context>"],
            "last-assistant-message": .string(Self.reply)
        ])
        #expect(AgentEventInterpreter.interpret(event, status: .working, agentSessionId: agentId) == AgentEventOutcome())
        var session = Session(id: event.sessionId, name: "Chat", kind: .codex, agentSessionId: agentId)
        session.pendingWork = PendingAgentWork(launchId: UUID(), since: .reference)
        let receipt = HiveEvent(sessionId: event.sessionId, source: event.source, name: event.name,
                                payload: event.payload, launchId: session.pendingWork?.launchId)
        #expect(InterruptedWork.reconcile(session, events: [receipt]) == session.pendingWork)
    }

    @Test("Los JSON reales y una respuesta posterior a un pedido interno siguen siendo mensajes")
    func realReply() {
        for inputs in [["Devolvé JSON con summary y next_action"], [Self.prompt, "Ahora revisá los permisos"], []] {
            let event = HiveEvent(sessionId: UUID(), source: "codex", name: "notify", payload: [
                "type": "agent-turn-complete", "thread-id": "original",
                "input-messages": .array(inputs.map(JSONValue.string)), "last-assistant-message": .string(Self.reply)
            ])
            #expect(!CodexInternalTurn.isCompletion(event))
            #expect(AgentEventInterpreter.interpret(event, status: .working, agentSessionId: "original").reply == Self.reply)
        }
    }

    @Test("Limpia el turno auxiliar con respaldo, sin borrar un /new real ni JSON del usuario")
    func repairHistory() throws {
        let dir = TempDir("codex-history-repair")
        let store = HistoryStore(directory: dir.url)
        let session = Session(name: "Permisos", kind: .codex)
        store.ensureMarkdown(session: session, place: "app › main")
        func entry(_ role: HistoryEntry.Role, _ text: String, _ offset: Double = 0) -> HistoryEntry {
            HistoryEntry(date: Date.reference.addingTimeInterval(offset), role: role, text: text, agent: .codex)
        }
        let original = [entry(.user, "Revisá los permisos"), entry(.assistant, "Corregidos y comprobados en local."),
                        entry(.marker, "Nueva conversación", 10), entry(.user, Self.prompt, 10), entry(.assistant, Self.reply, 10),
                        entry(.marker, "Nueva conversación", 20), entry(.user, "Devolvé JSON con summary y next_action", 20),
                        entry(.assistant, Self.reply, 20)]
        for e in original { store.append(e, sessionId: session.id, agentName: "Codex") }
        let raw = try Data(contentsOf: store.jsonlURL(session.id))
        #expect(store.load(session.id) == Array(original.prefix(2)) + Array(original.suffix(3)))
        #expect(try store.repairCodexInternalTurns(session: session, place: "app › main"))
        #expect(!store.fullTimeline(session.id, agent: .codex).contains { $0.text == Self.prompt })
        let markdown = try String(contentsOf: store.markdownURL(session.id), encoding: .utf8)
        #expect(!markdown.contains(Self.prompt))
        #expect(markdown.contains("Corregidos y comprobados en local.") && markdown.contains(Self.reply))
        let backups = try FileManager.default.contentsOfDirectory(at: dir.url.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0].appendingPathComponent(store.jsonlURL(session.id).lastPathComponent)) == raw)
        #expect(try !store.repairCodexInternalTurns(session: session, place: "app › main"))
    }
}
