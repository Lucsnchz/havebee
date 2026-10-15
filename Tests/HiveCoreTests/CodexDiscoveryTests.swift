import Foundation
import Testing
@testable import HiveCore

/// Rollouts falsos de Codex: el padre, sus subagentes y una ventana de VS Code en la misma carpeta.
@Suite("Codex: descubrimiento sin subagentes")
struct CodexDiscoveryTests {
    let codex = TempDir("hive-codex")
    let now = Date()
    var storage: AgentStorage {
        AgentStorage(claudeConfigDir: codex.url.appendingPathComponent("claude"), codexHome: codex.url,
                     geminiHome: codex.url.appendingPathComponent("gemini"))
    }

    /// Escribe un rollout con su session_meta. `source` es el JSON crudo del campo.
    @discardableResult
    func rollout(_ id: String, cwd: String = "/code/x", source: String = #""cli""#, created: Date, modified: Date? = nil,
                 extra: String = "") throws -> URL {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: created)
        let day = String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!)
        let stamp = created.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let meta = #"{"timestamp":"\#(stamp)","type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(stamp)","cwd":"\#(cwd)","originator":"codex_cli_rs","cli_version":"0.162.1","source":\#(source)\#(extra)}}"#
        let file = codex.write("\(day)/rollout-2026-10-12T10-00-00-\(id).jsonl", meta + "\n{\"type\":\"event_msg\"}\n")
        try FileManager.default.setAttributes([.modificationDate: modified ?? created], ofItemAtPath: file.path)
        return file
    }

    @Test("Con padre, subagente y VS Code en la misma carpeta, devuelve el padre")
    func parentWins() throws {
        let since = now.addingTimeInterval(-400)
        try rollout("padre", created: now.addingTimeInterval(-300), modified: now.addingTimeInterval(-200))
        try rollout("subagente", source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"padre","depth":1}}}"#,
                    created: now.addingTimeInterval(-120), modified: now.addingTimeInterval(-5))
        try rollout("vscode", source: #""vscode""#, created: now.addingTimeInterval(-30), modified: now)
        #expect(storage.discoverCodexThread(cwd: "/code/x", since: since, excluding: [], now: now) == "padre")
        // Sin el padre, ni el subagente ni VS Code sirven.
        #expect(storage.discoverCodexThread(cwd: "/code/x", since: since, excluding: ["padre"], now: now) == nil)
    }

    @Test("thread_source = subagent también se descarta")
    func threadSource() throws {
        try rollout("hijo", source: #""exec""#, created: now.addingTimeInterval(-50), extra: #","thread_source":"subagent""#)
        #expect(storage.discoverCodexThread(cwd: "/code/x", since: now.addingTimeInterval(-60), excluding: [], now: now) == nil)
    }

    @Test("Gana el creado más cerca del arranque, no el último modificado")
    func creationTime() throws {
        let since = now.addingTimeInterval(-600)
        try rollout("primero", created: since.addingTimeInterval(3), modified: now.addingTimeInterval(-300))
        try rollout("despues", created: since.addingTimeInterval(200), modified: now)
        // Creado antes del arranque (aunque se haya escrito después): es de otra ejecución.
        try rollout("viejo", created: since.addingTimeInterval(-120), modified: now)
        #expect(storage.discoverCodexThread(cwd: "/code/x", since: since, excluding: [], now: now) == "primero")
        // Un margen de 5 s antes del arranque cuenta (el reloj de Codex y el de Hive no coinciden justo).
        try rollout("justo", created: since.addingTimeInterval(-2), modified: now)
        #expect(storage.discoverCodexThread(cwd: "/code/x", since: since, excluding: [], now: now) == "justo")
        #expect(storage.discoverCodexThread(cwd: "/code/otra", since: since, excluding: [], now: now) == nil)
    }

    @Test("Sabe si un thread es de un subagente y encuentra su archivo")
    func subagentThread() throws {
        let parent = try rollout("019a-padre", created: now)
        try rollout("019a-hijo", source: #"{"subagent":"review"}"#, created: now)
        #expect(storage.codexRolloutURL("019a-padre")?.lastPathComponent == parent.lastPathComponent)
        #expect(!storage.isCodexSubagentThread("019a-padre"))
        #expect(storage.isCodexSubagentThread("019a-hijo"))
        #expect(!storage.isCodexSubagentThread("no-existe"))
        #expect(storage.codexRolloutURL("no-existe") == nil)
        #expect(storage.codexRolloutURL("") == nil)
        // Los archivados también se encuentran.
        codex.write("archived_sessions/rollout-2026-01-01T00-00-00-019a-archivado.jsonl", "{}")
        #expect(storage.codexRolloutURL("019a-archivado") != nil)
    }

    @Test("Un aviso de un thread de subagente no cambia el id ni el historial")
    func subagentEventIgnored() {
        let event = HiveEvent(sessionId: UUID(), source: "codex", name: "notify", payload: [
            "type": "agent-turn-complete", "thread-id": "hijo", "input-messages": ["Revisá"], "last-assistant-message": "Revisado",
        ])
        let ignored = AgentEventInterpreter.interpret(event, status: .working, agentSessionId: "padre", isSubagentThread: { $0 == "hijo" })
        #expect(ignored == AgentEventOutcome())
        // Sin la consulta (o si no es subagente) se comporta como antes.
        let before = AgentEventInterpreter.interpret(event, status: .working, agentSessionId: "padre")
        #expect(before.agentSessionId == "hijo")
        #expect(before.history.first?.role == .marker)
        // El thread propio nunca se consulta.
        let own = HiveEvent(sessionId: UUID(), source: "codex", name: "notify", payload: ["type": "agent-turn-complete", "thread-id": "padre"])
        let mine = AgentEventInterpreter.interpret(own, status: .working, agentSessionId: "padre", isSubagentThread: { _ in true })
        #expect(mine.status == .waiting)
    }

    @Test("Las fechas de los agentes se leen con y sin fracciones de segundo")
    func timestamps() {
        #expect(AgentTimestamp.parse("2026-10-12T13:24:05.123Z") != nil)
        #expect(AgentTimestamp.parse("2026-10-12T13:24:05Z") != nil)
        #expect(AgentTimestamp.parse("ayer") == nil)
    }
}
