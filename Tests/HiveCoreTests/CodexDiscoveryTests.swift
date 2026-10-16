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

    /// Un UUID v7 como los de Codex: los primeros 48 bits son los milisegundos de `date`.
    func uuidV7(_ date: Date, node: String = "000000000001") -> String {
        let hex = String(format: "%012llx", UInt64(date.timeIntervalSince1970 * 1000))
        return "\(hex.prefix(8))-\(hex.suffix(4))-7000-8000-\(node)"
    }

    @Test("Un thread con UUID v7 se busca en la carpeta de su día, sin recorrer sessions/ entero")
    func rolloutByDate() throws {
        let created = now.addingTimeInterval(-3 * 86_400)
        let id = uuidV7(created)
        let decoded = try #require(AgentStorage.uuidV7Date(id))
        #expect(abs(decoded.timeIntervalSince(created)) < 0.01)
        #expect(AgentStorage.uuidV7Date("019a12e6-0000-7000-8000-000000000001") == Date(timeIntervalSince1970: 0x019a_12e6_0000 / 1000))
        #expect(AgentStorage.uuidV7Date("6f1c3a2e-9b1d-4c5e-8f00-000000000001") == nil) // v4
        #expect(AgentStorage.uuidV7Date("t-1") == nil)

        let own = try rollout(id, created: created)
        // Otro archivo con el mismo thread en una carpeta vieja: recorriendo todo podría ganar ese.
        codex.write("sessions/2020/01/01/rollout-2020-01-01T00-00-00-\(id).jsonl", "{}")
        #expect(storage.codexRolloutURL(id)?.path == own.path)
        #expect(!storage.isCodexSubagentThread(id))

        // Si no está en la carpeta de su día (lo movieron), se busca igual en todo sessions/.
        let moved = uuidV7(now, node: "000000000002")
        let elsewhere = codex.write("sessions/2019/05/05/rollout-2019-05-05T00-00-00-\(moved).jsonl", "{}")
        #expect(storage.codexRolloutURL(moved)?.path == elsewhere.path)
        // Y en los archivados.
        let archived = uuidV7(now, node: "000000000003")
        let file = codex.write("archived_sessions/rollout-2026-01-01T00-00-00-\(archived).jsonl", "{}")
        #expect(storage.codexRolloutURL(archived)?.path == file.path)
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
