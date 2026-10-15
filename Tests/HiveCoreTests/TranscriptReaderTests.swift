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
