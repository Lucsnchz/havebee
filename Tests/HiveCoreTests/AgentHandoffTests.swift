import Foundation
import Testing
@testable import HiveCore

@Suite("Contexto al cambiar de IA")
struct AgentHandoffTests {
    @Test("Cada transcript se lee con su agente y conserva su autor después de borrar los originales")
    func mixedTranscripts() throws {
        let dir = TempDir()
        let history = HistoryStore(directory: dir.subdir("history"))
        let session = Session(name: "Compartida", kind: .claude)
        let claude = dir.write("claude.jsonl", AHFixtures.claudeTranscript)
        let codex = dir.write("codex.jsonl", AHFixtures.codexRollout)
        history.recordTranscript(sessionId: session.id, agent: .claude, conversationId: "c-1", path: claude.path)
        history.recordTranscript(sessionId: session.id, agent: .codex, conversationId: "codex", path: codex.path)
        let live = history.fullTimeline(session.id, agent: .codex)
        #expect(live.contains { $0.text == "Voy a revisar el checkout primero." && $0.agent == .claude })
        #expect(live.contains { $0.text == "Revisé el controlador de sesiones." && $0.agent == .codex })
        let agents = AgentStorage(claudeConfigDir: dir.subdir("claude"), codexHome: dir.subdir("codex"), geminiHome: dir.subdir("gemini"))
        try history.prepareHandoff(session: session, place: "app › main", agents: agents, directory: dir.path, excluding: [], now: .reference)
        try FileManager.default.removeItem(at: claude)
        try FileManager.default.removeItem(at: codex)
        let archived = history.fullTimeline(session.id, agent: .claude)
        #expect(archived.map(\.id) == live.map(\.id))
        #expect(archived.map(\.text) == live.map(\.text))
        #expect(archived.map(\.agent) == live.map(\.agent))
        let markdown = try String(contentsOf: history.markdownURL(session.id), encoding: .utf8)
        #expect(markdown.contains("## Claude Code") && markdown.contains("## Codex"))
        #expect(markdown.contains("Voy a revisar el checkout primero.") && markdown.contains("Revisé el controlador de sesiones."))
        #expect(HistoryExport.plainText(live, agent: "desconocido").contains("Codex: Revisé"))
    }

    @Test("No resucita los archivos de una sesión eliminada")
    func deleted() {
        let dir = TempDir()
        let history = HistoryStore(directory: dir.subdir("history"))
        let session = Session(name: "Eliminada", kind: .claude)
        history.ensureMarkdown(session: session, place: "app")
        history.delete(session.id)
        let agents = AgentStorage(claudeConfigDir: dir.subdir("claude"), codexHome: dir.subdir("codex"), geminiHome: dir.subdir("gemini"))
        #expect(throws: CancellationError.self) {
            try history.prepareHandoff(session: session, place: "app", agents: agents, directory: dir.path, excluding: [], now: .reference)
        }
        #expect(!FileManager.default.fileExists(atPath: history.markdownURL(session.id).path))
        #expect(!FileManager.default.fileExists(atPath: history.jsonlURL(session.id).path))
    }

    @Test("El extracto es acotado y mantiene acceso al historial completo")
    func boundedContext() {
        let entries = [HistoryEntry(date: .reference, role: .assistant, text: String(repeating: "á", count: 200_000) + "lo último", agent: .claude)]
        let instructions = AgentHandoff.instructions(from: .claude, markdown: URL(fileURLWithPath: "/mis datos/historial.md"), entries: entries)
        #expect(instructions.count < 14_000)
        #expect(instructions.contains("lo último") && instructions.contains("/mis datos/historial.md"))
        #expect(HistoryStore.markerMeaning(AgentHandoff.markerPrefix + "Claude → Codex").contains("contexto compartido"))
    }

    @Test("Lee la generación del proceso en eventos nuevos y sigue leyendo el formato anterior")
    func eventGeneration() throws {
        let id = UUID(), generation = UUID()
        let event = try #require(HiveEvent.parse("\(id)\tclaude\tStop\t\(generation)\n{}"))
        #expect(event.launchId == generation)
        #expect(HiveEvent.parse("\(id)\tcodex\tnotify\n{}")?.launchId == nil)
    }
}
