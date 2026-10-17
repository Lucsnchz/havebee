import Foundation
import Testing
@testable import HiveCore

/// Codex manda en `input-messages` todos los pedidos que siguen en su contexto (tras compactarlo,
/// también los de turnos anteriores). Las versiones anteriores los guardaban juntos en cada turno.
@Suite("Codex: el pedido de cada turno en el historial")
struct CodexTurnPromptTests {
    static let thread = "019a12e6-0000-7000-8000-0000000000aa"
    static let image = #"<image name=[Image #1] path="/tmp/captura.png">"# + "\n</image>\n[Image #1] mirá esto"

    @Test("De todos los pedidos que trae el aviso, guarda solo el del turno")
    func onlyTurnPrompt() {
        let event = HiveEvent(sessionId: UUID(), source: "codex", name: "notify", payload: [
            "type": "agent-turn-complete", "thread-id": .string(Self.thread),
            "input-messages": ["Revisá el login", "Ahora los tests", "Subilo", "<environment_context>x</environment_context>"],
            "last-assistant-message": "Subido.",
        ])
        let o = AgentEventInterpreter.interpret(event, status: .working, agentSessionId: Self.thread)
        #expect(o.history.map(\.role) == [.user, .assistant])
        #expect(o.history.first?.text == "Subilo")
    }

    /// Un rollout con tres turnos (uno con imagen) y el registro que guardaban las versiones anteriores.
    private func world(_ dir: TempDir) throws -> (store: HistoryStore, session: Session) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ offset: Double, _ type: String, _ payload: [String: Any]) throws -> String {
            let object: [String: Any] = ["timestamp": formatter.string(from: Date.reference.addingTimeInterval(offset)),
                                         "type": type, "payload": payload]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        func message(_ offset: Double, _ role: String, _ texts: [String]) throws -> String {
            let kind = role == "user" ? "input_text" : "output_text"
            return try line(offset, "response_item", ["type": "message", "role": role,
                                                      "content": texts.map { ["type": kind, "text": $0] }])
        }
        let rollout = try [
            line(0, "session_meta", ["id": Self.thread, "cwd": "/code/app"]),
            message(1, "user", ["Revisá el login"]),
            message(5, "assistant", ["Revisado."]),
            message(60, "user", [#"<image name=[Image #1] path="/tmp/captura.png">"#, "</image>", "[Image #1] mirá esto"]),
            message(65, "assistant", ["Lo veo."]),
            message(120, "user", ["Subilo"]),
            message(125, "assistant", ["Subido."]),
        ].joined(separator: "\n") + "\n"
        let rolloutURL = dir.url.appendingPathComponent("rollout-2026-10-12T13-00-00-\(Self.thread).jsonl")
        try rollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let store = HistoryStore(directory: dir.url.appendingPathComponent("history"))
        let session = Session(name: "Login", kind: .codex)
        store.ensureMarkdown(session: session, place: "app › main")
        func entry(_ offset: Double, _ role: HistoryEntry.Role, _ text: String) -> HistoryEntry {
            HistoryEntry(date: Date.reference.addingTimeInterval(offset), role: role, text: text, agent: .codex)
        }
        let log = [
            // Anterior a la copia del rollout: solo está en el registro.
            entry(-100, .user, "Hola"), entry(-100, .assistant, "Hola, ¿qué hacemos?"),
            entry(10, .user, "Revisá el login"), entry(10, .assistant, "Revisado."),
            entry(70, .user, "Revisá el login\n\n[Image #1] mirá esto"), entry(70, .assistant, "Lo veo."),
            entry(130, .user, "Revisá el login\n\n[Image #1] mirá esto\n\nSubilo"), entry(130, .assistant, "Subido."),
            // Después de lo que tiene el rollout: tampoco se pierde.
            entry(200, .user, "Nuevo pedido"),
        ]
        for e in log { store.append(e, sessionId: session.id, agentName: "Codex") }
        store.recordTranscript(sessionId: session.id, agent: .codex, conversationId: Self.thread, path: rolloutURL.path,
                               now: Date.reference)
        return (store, session)
    }

    @Test("La línea de tiempo muestra cada pedido una vez y conserva las respuestas de Codex")
    func timelineWithoutRepeatedPrompts() throws {
        let dir = TempDir("codex-turn-prompts")
        let (store, session) = try world(dir)
        let timeline = store.fullTimeline(session.id, agent: .codex)
        #expect(timeline.filter { $0.role == .user }.map(\.text) == ["Hola", "Revisá el login", Self.image, "Subilo", "Nuevo pedido"])
        #expect(timeline.filter { $0.role == .assistant }.map(\.text) == ["Hola, ¿qué hacemos?", "Revisado.", "Lo veo.", "Subido."])

        let handoff = AgentHandoff.instructions(from: .codex, markdown: store.markdownURL(session.id), entries: timeline)
        #expect(handoff.contains("Codex: Subido.") && handoff.contains("Codex: Lo veo."))
        #expect(!handoff.contains("Revisá el login\n\n[Image #1]"))
    }

    @Test("La reparación saca los pedidos repetidos del registro y del Markdown, con respaldo")
    func repairRepeatedPrompts() throws {
        let dir = TempDir("codex-turn-prompts-repair")
        let (store, session) = try world(dir)
        let raw = try Data(contentsOf: store.jsonlURL(session.id))
        #expect(try store.repairCodexHistory(session: session, place: "app › main"))
        #expect(!store.load(session.id).contains { $0.text.contains("mirá esto\n\n") || $0.text.hasSuffix("\n\nSubilo") })
        #expect(store.load(session.id).filter { $0.role == .user }.map(\.text) == ["Hola", "Revisá el login", "Nuevo pedido"])
        let markdown = try String(contentsOf: store.markdownURL(session.id), encoding: .utf8)
        #expect(!markdown.contains("mirá esto\n\nSubilo"))
        #expect(markdown.contains("## Codex") && markdown.contains("Lo veo.") && markdown.contains("Nuevo pedido"))
        let backups = try FileManager.default.contentsOfDirectory(at: store.directory.appendingPathComponent("backups"),
                                                                  includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0].appendingPathComponent(store.jsonlURL(session.id).lastPathComponent)) == raw)
        #expect(try !store.repairCodexHistory(session: session, place: "app › main"))
    }
}
