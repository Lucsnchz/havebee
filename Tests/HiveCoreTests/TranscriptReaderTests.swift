import Foundation
import Testing
@testable import HiveCore

@Suite("Transcripts de los agentes")
struct TranscriptReaderTests {
    @Test("Claude: lo que escribiste y los textos de la IA, sin herramientas, subagentes ni mensajes internos")
    func claude() {
        let messages = TranscriptReader.parseClaude(AHFixtures.claudeTranscript, fallbackConversationId: "otro")
        #expect(messages.map(\.text) == [
            "Agregá validación de stock al checkout",
            "Voy a revisar el checkout primero.",
            "Listo: agregué la **validación** de stock.\n\n```php\nif ($item->stock < $qty) {\n    throw new OutOfStock();\n}\n```",
            "¿Y el carrito también?",
            "<task-notification>El build terminó bien</task-notification>",
            "Sí, el carrito usa la misma regla.",
            "Los tests pasan.",
        ])
        #expect(messages.map(\.role) == [.user, .assistant, .assistant, .user, .system, .assistant, .assistant])
        #expect(Set(messages.map(\.conversationId)) == ["c-1"])
        // Cada bloque tiene su clave, estable entre lecturas.
        #expect(messages.map(\.key) == ["u1", "a1#0", "a3#1", "u6", "u7", "a4#0", "a4#1"])
        #expect(messages[0].date == AgentTimestamp.parse("2026-09-21T14:00:00.000Z"))
        #expect(TranscriptReader.parseClaude(AHFixtures.claudeTranscript, fallbackConversationId: "otro") == messages)
    }

    @Test("Codex: los mensajes del usuario y de la IA, sin el contexto que inyecta")
    func codex() {
        let messages = TranscriptReader.parseCodex(AHFixtures.codexRollout, fallbackConversationId: "otro")
        #expect(messages.map(\.text) == ["Arreglá el login", "Revisé el controlador de sesiones.", "Listo, el login funciona y los 12 tests pasan."])
        #expect(messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(Set(messages.map(\.conversationId)) == ["019a12e6-0000-7000-8000-000000000001"])
        #expect(Set(messages.map(\.key)).count == 3)
        #expect(TranscriptReader.parseCodex(AHFixtures.codexRollout, fallbackConversationId: "x").map(\.key) == messages.map(\.key))
    }

    @Test("El ID de la conversación sale del nombre del archivo si adentro no está")
    func conversationFromName() {
        #expect(TranscriptReader.conversationId(fromFileName: "c-9.jsonl", agent: .claude) == "c-9")
        #expect(TranscriptReader.conversationId(fromFileName: "rollout-2026-10-12T10-30-00-019a12e6-0000-7000-8000-000000000001.jsonl",
                                                agent: .codex) == "019a12e6-0000-7000-8000-000000000001")
        let lines = #"{"type":"user","message":{"content":"hola"},"uuid":"u"}"#
        #expect(TranscriptReader.parseClaude(lines, fallbackConversationId: "del-archivo").first?.conversationId == "del-archivo")
    }

    @Test("Lee del disco y vuelve a leer cuando el archivo cambia")
    func readsAndRefreshes() throws {
        let dir = TempDir("hive-transcripts")
        let file = dir.write("projects/-code/c-1.jsonl", AHFixtures.claudeTranscript)
        #expect(TranscriptReader.read(file, agent: .claude).count == 7)
        #expect(TranscriptReader.read(file, agent: .claude).count == 7) // de la caché
        let extra = #"{"type":"user","message":{"content":"Una más"},"uuid":"u9","sessionId":"c-1","timestamp":"2026-09-21T15:00:00Z"}"#
        try (AHFixtures.claudeTranscript + "\n" + extra + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(TranscriptReader.read(file, agent: .claude).last?.text == "Una más")
        let rollout = dir.write("rollout-2026-10-12T13-00-00-019a12e6-0000-7000-8000-000000000001.jsonl", AHFixtures.codexRollout)
        #expect(TranscriptReader.read(rollout, agent: .codex).count == 3)
        #expect(TranscriptReader.read(dir.url.appendingPathComponent("no-existe.jsonl"), agent: .claude).isEmpty)
    }

    /// Agrega texto al final sin reemplazar el archivo (como hacen los agentes).
    func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func claudeLine(_ uuid: String, _ text: String, type: String = "assistant") -> String {
        type == "user"
            ? #"{"type":"user","message":{"content":"\#(text)"},"uuid":"\#(uuid)","sessionId":"c-1","timestamp":"2026-09-21T15:00:00Z"}"#
            : #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(text)"}]},"uuid":"\#(uuid)","sessionId":"c-1","timestamp":"2026-09-21T15:00:00Z"}"#
    }

    @Test("Sigue leyendo desde donde quedó, también con la última línea a medio escribir")
    func incremental() throws {
        let dir = TempDir("hive-transcripts")
        let file = dir.write("c-1.jsonl", claudeLine("u1", "Hola", type: "user") + "\n")
        #expect(TranscriptReader.read(file, agent: .claude).map(\.text) == ["Hola"])
        // El agente está escribiendo una línea: todavía no es JSON válido.
        let line = claudeLine("a1", "Respuesta completa")
        try append(String(line.prefix(30)), to: file)
        #expect(TranscriptReader.read(file, agent: .claude).map(\.text) == ["Hola"])
        // Termina la línea (sin salto todavía): se lee, pero no cuenta como leída.
        try append(String(line.dropFirst(30)), to: file)
        #expect(TranscriptReader.read(file, agent: .claude).map(\.text) == ["Hola", "Respuesta completa"])
        // Llega el salto y otra línea: nada se repite.
        try append("\n" + claudeLine("u2", "Otra", type: "user") + "\n", to: file)
        let messages = TranscriptReader.read(file, agent: .claude)
        #expect(messages.map(\.text) == ["Hola", "Respuesta completa", "Otra"])
        #expect(messages.map(\.key) == ["u1", "a1#0", "u2"])
        // Leer todo de nuevo da lo mismo que la lectura por partes.
        let whole = try String(contentsOf: file, encoding: .utf8)
        #expect(TranscriptReader.parseClaude(whole, fallbackConversationId: "c-1") == messages)
    }

    @Test("Si el archivo se reescribe, lo vuelve a leer entero")
    func rewritten() throws {
        let dir = TempDir("hive-transcripts")
        let file = dir.write("c-1.jsonl", claudeLine("u1", "Primero", type: "user") + "\n" + claudeLine("a1", "Viejo") + "\n")
        #expect(TranscriptReader.read(file, agent: .claude).count == 2)
        // Mismo archivo (sin cambiar de inodo), con otro contenido más largo.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((claudeLine("u9", "Distinto", type: "user") + "\n" + claudeLine("a9", "Nuevo y bastante más largo que antes") + "\n").utf8))
        try handle.close()
        #expect(TranscriptReader.read(file, agent: .claude).map(\.text) == ["Distinto", "Nuevo y bastante más largo que antes"])
        // Y si se achica, también.
        let shorter = try FileHandle(forWritingTo: file)
        try shorter.truncate(atOffset: 0)
        try shorter.write(contentsOf: Data((claudeLine("u5", "Corto", type: "user") + "\n").utf8))
        try shorter.close()
        #expect(TranscriptReader.read(file, agent: .claude).map(\.text) == ["Corto"])
    }

    @Test("Las líneas internas grandes se descartan sin perder mensajes")
    func skipsInternalLines() {
        let lines = [
            // Pedido a la API con mensajes adentro: no es parte de la charla.
            #"{"type":"api-request","request":{"messages":[{"type":"user","message":{"content":"no va"}},{"type":"text","text":"tampoco"}]},"uuid":"r1"}"#,
            #"{"uuid":"u1","message":{"content":"Pedido con \"type\":\"tool_result\" escrito a mano"},"type":"user","sessionId":"c-1"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"salida"}]},"uuid":"u2"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"content":"x"}}]},"uuid":"a1"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"},{"type":"text","text":"Mirando"}]},"uuid":"a2"}"#,
            // Con espacios (otro formato): se parsea igual.
            #"{ "type" : "assistant", "message": { "content": [ { "type": "text", "text": "Con espacios" } ] }, "uuid": "a3" }"#,
        ].joined(separator: "\n")
        #expect(TranscriptReader.parseClaude(lines, fallbackConversationId: "c-1").map(\.text)
            == [#"Pedido con "type":"tool_result" escrito a mano"#, "Mirando", "Con espacios"])
    }

    @Test("Lee el «type» de primer nivel sin parsear la línea", arguments: [
        (#"{"type":"user","message":{}}"#, "user"),
        (#"{"a":{"type":"no"},"b":[1,{"type":"tampoco"}],"c":"}\"{","type":"assistant"}"#, "assistant"),
        (#"  { "n": -1.5e3 , "ok": true, "z": null, "type" : "api-request" }"#, "api-request"),
    ])
    func topLevelType(line: String, expected: String) {
        #expect(JSONLine.topLevelString("type", in: Data(line.utf8)[...]) == expected)
    }

    @Test("Sin «type» de primer nivel o con una línea rara, no adivina", arguments: [
        #"{"message":{"type":"user"}}"#,
        #"{"type":1}"#,
        #"{"type":"con \"escape\""}"#,
        #"[{"type":"user"}]"#,
        #"{"type""#,
        #"{"a":[1,2}"#,
        "",
    ])
    func topLevelTypeMissing(line: String) {
        #expect(JSONLine.topLevelString("type", in: Data(line.utf8)[...]) == nil)
    }

    @Test("Ubica los transcripts de Claude y de Codex")
    func locations() {
        let claude = TempDir("hive-claude"), codex = TempDir("hive-codex")
        let storage = AgentStorage(claudeConfigDir: claude.url, codexHome: codex.url, geminiHome: codex.url)
        #expect(storage.claudeTranscriptURL("c-1") == nil)
        let file = claude.write("projects/-code-ecommerce/c-1.jsonl", "{}")
        #expect(storage.claudeTranscriptURL("c-1")?.path == file.path)
        #expect(storage.claudeTranscriptURL("") == nil)
        let rollout = codex.write("sessions/2026/10/12/rollout-2026-10-12T13-00-00-t-1.jsonl", "{}")
        #expect(storage.codexRolloutURL("t-1")?.path == rollout.path)
    }

    @Test("El hash estable no cambia entre ejecuciones")
    func stableHash() {
        #expect(TranscriptReader.stableHash("hola") == TranscriptReader.stableHash("hola"))
        #expect(TranscriptReader.stableHash("hola") != TranscriptReader.stableHash("chau"))
        #expect(TranscriptReader.stableHash("") == "cbf29ce484222325")
    }
}
