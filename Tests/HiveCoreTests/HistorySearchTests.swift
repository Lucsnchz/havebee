import Foundation
import Testing
@testable import HiveCore

@Suite("Historial completo: copia de los transcripts, búsqueda y eliminadas")
struct HistorySearchTests {
    let dir = TempDir("hive-history")
    var store: HistoryStore { HistoryStore(directory: dir.url.appendingPathComponent("history")) }

    func date(_ iso: String) -> Date { AgentTimestamp.parse(iso)! }

    /// Lo que Hive anotó por los hooks durante la conversación del fixture de Claude.
    func logFromHooks(_ id: UUID) {
        store.append(HistoryEntry(date: date("2026-09-21T14:00:00.500Z"), role: .user, text: "Agregá validación de stock al checkout"),
                     sessionId: id, agentName: "Claude Code")
        store.append(HistoryEntry(date: date("2026-09-21T14:01:01Z"), role: .assistant,
                                  text: "Listo: agregué la **validación** de stock.\n\n```php\nif ($item->stock < $qty) {\n    throw new OutOfStock();\n}\n```"),
                     sessionId: id, agentName: "Claude Code")
        store.append(HistoryEntry(date: date("2026-09-21T14:04:01Z"), role: .assistant, text: "Sí, el carrito usa la misma regla.\n\nLos tests pasan."),
                     sessionId: id, agentName: "Claude Code")
        store.append(HistoryEntry(date: date("2026-09-21T14:05:00Z"), role: .marker, text: "/clear"), sessionId: id, agentName: "Claude Code")
    }

    @Test("archiveTranscript copia los textos sin duplicar y sobreviven al transcript original")
    func archive() throws {
        let id = UUID()
        let transcript = dir.write("claude/projects/-code/c-1.jsonl", AHFixtures.claudeTranscript)
        #expect(store.archiveTranscript(sessionId: id, agent: .claude, path: transcript.path) == 7)
        #expect(store.archiveTranscript(sessionId: id, agent: .claude, path: transcript.path) == 0)
        // Llega un mensaje más: solo se agrega ese.
        let extra = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Ya subí el cambio."}]},"uuid":"a9","sessionId":"c-1","timestamp":"2026-09-21T14:04:30Z"}"#
        try (AHFixtures.claudeTranscript + "\n" + extra).write(to: transcript, atomically: true, encoding: .utf8)
        #expect(store.archiveTranscript(sessionId: id, agent: .claude, path: transcript.path) == 1)
        let lines = try String(contentsOf: store.fullURL(id), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 8)

        // Claude borra sus transcripts a los 30 días: la copia de Hive sigue.
        try FileManager.default.removeItem(at: transcript)
        logFromHooks(id)
        let timeline = store.fullTimeline(id, agent: .claude)
        #expect(timeline.contains { $0.text == "Voy a revisar el checkout primero." })
        // Lo que ya está en la copia no se repite desde el registro de los hooks; el /clear se conserva.
        #expect(timeline.filter { $0.text == "Agregá validación de stock al checkout" }.count == 1)
        #expect(timeline.filter { $0.text.hasPrefix("Listo: agregué") }.count == 1)
        #expect(!timeline.contains { $0.text == "Sí, el carrito usa la misma regla.\n\nLos tests pasan." }) // venía en dos bloques
        #expect(timeline.last?.role == .marker)
        #expect(timeline.map(\.date) == timeline.map(\.date).sorted())
        // Los IDs no cambian entre lecturas (el panel salta a una coincidencia por ID).
        #expect(store.fullTimeline(id, agent: .claude).map(\.id) == timeline.map(\.id))
    }

    @Test("La línea de tiempo suma el transcript vivo de la conversación actual")
    func liveTranscript() {
        let id = UUID()
        let rollout = dir.write("codex/sessions/rollout-2026-10-12T13-00-00-019a12e6-0000-7000-8000-000000000001.jsonl", AHFixtures.codexRollout)
        store.append(HistoryEntry(date: date("2026-10-12T13:00:23Z"), role: .user, text: "Arreglá el login"), sessionId: id, agentName: "Codex")
        store.append(HistoryEntry(date: date("2026-10-12T13:00:23Z"), role: .assistant, text: "Listo, el login funciona y los 12 tests pasan."),
                     sessionId: id, agentName: "Codex")
        #expect(store.fullTimeline(id, agent: .codex).count == 2) // sin transcript: el registro de siempre
        let timeline = store.fullTimeline(id, agent: .codex, live: [rollout])
        #expect(timeline.map(\.text) == ["Arreglá el login", "Revisé el controlador de sesiones.", "Listo, el login funciona y los 12 tests pasan."])
        // Archivado y vivo a la vez no se duplican.
        store.archiveTranscript(sessionId: id, agent: .codex, path: rollout.path)
        #expect(store.fullTimeline(id, agent: .codex, live: [rollout]).count == 3)
    }

    @Test("recordTranscript anota una conversación por segmento")
    func segments() {
        let id = UUID()
        #expect(store.transcriptSegments(id).isEmpty)
        store.recordTranscript(sessionId: id, agent: .claude, conversationId: "c-1", path: "/a/c-1.jsonl", now: .reference)
        store.recordTranscript(sessionId: id, agent: .claude, conversationId: "c-1", path: "/a/c-1.jsonl", now: .reference.addingTimeInterval(60))
        store.recordTranscript(sessionId: id, agent: .claude, conversationId: "c-2", path: "/a/c-2.jsonl", now: .reference.addingTimeInterval(120))
        store.recordTranscript(sessionId: id, agent: .claude, conversationId: "c-2", path: "/b/c-2.jsonl", now: .reference.addingTimeInterval(180))
        store.recordTranscript(sessionId: id, agent: .claude, conversationId: "", path: "/x", now: .reference)
        let segments = store.transcriptSegments(id)
        #expect(segments.map(\.conversationId) == ["c-1", "c-2"])
        #expect(segments.map(\.path) == ["/a/c-1.jsonl", "/b/c-2.jsonl"])
        #expect(segments[1].since == .reference.addingTimeInterval(120))
        #expect(FileManager.default.fileExists(atPath: store.segmentsURL(id).path))
    }

    @Test("Copias completas y segmentos a la vez no duplican ni pierden nada")
    func concurrentWrites() throws {
        let id = UUID()
        let transcript = dir.write("c-1.jsonl", AHFixtures.claudeTranscript)
        let store = self.store
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            if i.isMultiple(of: 2) {
                store.archiveTranscript(sessionId: id, agent: .claude, path: transcript.path)
            } else {
                store.recordTranscript(sessionId: id, agent: .claude, conversationId: "c-\(i % 3)", path: "/p/\(i).jsonl")
            }
        }
        let lines = try String(contentsOf: store.fullURL(id), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 7)
        #expect(store.transcriptSegments(id).map(\.conversationId).sorted() == ["c-0", "c-1", "c-2"])
    }

    @Test("Buscar «validacion» encuentra «validación», sin distinguir mayúsculas")
    func search() throws {
        let a = UUID(), b = UUID()
        let transcript = dir.write("c-1.jsonl", AHFixtures.claudeTranscript)
        store.archiveTranscript(sessionId: a, agent: .claude, path: transcript.path)
        logFromHooks(a)
        store.append(HistoryEntry(date: date("2026-10-01T10:00:00Z"), role: .user, text: "Sumá VALIDACIÓN al registro"), sessionId: b, agentName: "Codex")
        store.append(HistoryEntry(date: date("2026-10-01T10:00:00Z"), role: .marker, text: "validacion en un marcador"), sessionId: b, agentName: "Codex")

        let hits = store.search("validacion")
        #expect(hits.map(\.sessionId) == [b, a, a]) // lo más nuevo primero, sin marcadores
        #expect(hits[0].snippet == "Sumá VALIDACIÓN al registro")
        #expect(hits[0].role == .user)
        #expect(Set(hits.dropFirst().map(\.role)) == [.user, .assistant])
        #expect(hits.allSatisfy { !$0.snippet.contains("\n") })
        // Limitado a algunas sesiones y a una cantidad.
        #expect(store.search("validacion", sessionIds: [a]).count == 2)
        #expect(store.search("validacion", limit: 1).map(\.sessionId) == [b])
        #expect(store.search("   ").isEmpty)
        #expect(store.search("no aparece nunca").isEmpty)
        // El ID del resultado es el de la entrada en la línea de tiempo.
        let entryIds = Set(store.fullTimeline(a, agent: .claude).map(\.id))
        #expect(hits.dropFirst().allSatisfy { entryIds.contains($0.entryId) })
    }

    @Test("El resultado de la búsqueda se encuentra en «Todo» aunque ahí se vea la copia del transcript")
    func jumpCounterpart() throws {
        let id = UUID()
        let transcript = dir.write("claude/projects/-code/c-1.jsonl", AHFixtures.claudeTranscript)
        logFromHooks(id) // sin copia completa todavía: la búsqueda devuelve entradas del registro
        let hits = store.search("carrito")
        let finalReply = try #require(hits.first { $0.role == .assistant })
        let timeline = store.fullTimeline(id, agent: .claude, live: [transcript])
        #expect(!timeline.contains { $0.id == finalReply.entryId }) // tapada por la copia del transcript
        let log = store.load(id)
        let target = try #require(log.first { $0.id == finalReply.entryId })
        // La respuesta final venía en dos bloques: entre las coincidencias (como en el panel), gana la
        // del mismo rol más cercana en el tiempo, y no el pedido «¿Y el carrito también?».
        let candidates = timeline.filter { HistoryExport.matches($0.text, query: "carrito") }
        #expect(candidates.count == 2)
        let resolved = try #require(HistoryExport.counterpart(of: target, in: candidates))
        #expect(timeline.first { $0.id == resolved }?.text == "Sí, el carrito usa la misma regla.")
        // Un pedido con el mismo texto se encuentra por su texto.
        let prompt = try #require(log.first { $0.role == .user })
        let promptMatch = try #require(HistoryExport.counterpart(of: prompt, in: timeline))
        #expect(timeline.first { $0.id == promptMatch }?.text == prompt.text)
        #expect(promptMatch != prompt.id)
        // Si la entrada está, es ella misma; sin candidatos, nada.
        #expect(HistoryExport.counterpart(of: prompt, in: log) == prompt.id)
        #expect(HistoryExport.counterpart(of: prompt, in: []) == nil)
    }

    @Test("Eliminar una sesión aparta sus archivos en history/deleted/ y purge los borra después")
    func deleteAndPurge() throws {
        let id = UUID(), other = UUID()
        store.ensureMarkdown(session: Session(id: id, name: "x", kind: .claude), place: "p")
        store.append(HistoryEntry(date: .reference, role: .user, text: "hola"), sessionId: id, agentName: "Claude Code")
        store.archiveTranscript(sessionId: id, agent: .claude, path: dir.write("c-1.jsonl", AHFixtures.claudeTranscript).path)
        store.recordTranscript(sessionId: id, agent: .claude, conversationId: "c-1", path: "/c-1.jsonl")
        store.append(HistoryEntry(date: .reference, role: .user, text: "otra"), sessionId: other, agentName: "Codex")

        store.delete(id, now: .reference)
        for url in [store.jsonlURL(id), store.markdownURL(id), store.fullURL(id), store.segmentsURL(id)] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(FileManager.default.fileExists(atPath: store.deletedDirectory.appendingPathComponent(url.lastPathComponent).path))
        }
        // Lo eliminado ya no aparece en la búsqueda.
        #expect(store.search("hola").isEmpty)
        #expect(store.search("otra").count == 1)
        // Una copia del transcript que termina después de eliminarla (corre en segundo plano) no la revive.
        let late = dir.write("c-late.jsonl", AHFixtures.claudeTranscript)
        #expect(store.archiveTranscript(sessionId: id, agent: .claude, path: late.path) == 0)
        store.recordTranscript(sessionId: id, agent: .claude, conversationId: "c-late", path: late.path)
        #expect(!FileManager.default.fileExists(atPath: store.fullURL(id).path))
        #expect(!FileManager.default.fileExists(atPath: store.segmentsURL(id).path))
        #expect(store.search("validacion").isEmpty)
        // Las otras sesiones siguen guardando su copia.
        #expect(store.archiveTranscript(sessionId: other, agent: .claude, path: late.path) == 7)

        store.purge(olderThan: 30 * 86_400, now: .reference.addingTimeInterval(29 * 86_400))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.deletedDirectory.path).count == 4)
        store.purge(olderThan: 30 * 86_400, now: .reference.addingTimeInterval(31 * 86_400))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.deletedDirectory.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.jsonlURL(other).path))
        store.delete(UUID()) // sin archivos: no hace nada
    }
}

@Suite("Copiar, filtrar y mostrar el historial")
struct HistoryExportTests {
    let entries = [
        HistoryEntry(date: .reference, role: .user, text: "Agregá la validación"),
        HistoryEntry(date: .reference, role: .assistant, text: "Listo:\n\n```php\n$x = 1;\n```"),
        HistoryEntry(date: .reference, role: .marker, text: "/clear"),
        HistoryEntry(date: .reference, role: .system, text: "<task-notification>ok</task-notification>"),
    ]

    @Test("Copiar todo: Vos, el agente, avisos y divisorias, separados por una línea en blanco")
    func plainText() {
        #expect(HistoryExport.plainText(entries, agent: "Claude Code") == """
        Vos: Agregá la validación

        Claude Code: Listo:

        ```php
        $x = 1;
        ```

        —— /clear ——

        Aviso automático: <task-notification>ok</task-notification>
        """)
        // Un corte se copia con la frase clara y el código de la API entre paréntesis.
        let cut = HistoryEntry(date: .reference, role: .marker, text: "⚠︎ Se cortó: rate_limit")
        #expect(HistoryExport.plainText(cut, agent: "Claude Code") == "—— ⚠︎ Se cortó: llegaste al límite de uso (rate_limit) ——")
        #expect(HistoryExport.plainText([], agent: "Codex").isEmpty)
    }

    @Test("Filtrar ignora mayúsculas y tildes y conserva las divisorias")
    func filter() {
        #expect(HistoryExport.filter(entries, query: "VALIDACION").map(\.role) == [.user, .marker])
        #expect(HistoryExport.filter(entries, query: "  ").count == 4)
        #expect(HistoryExport.matches("Ñandú", query: "nandu"))
        #expect(!HistoryExport.matches("hola", query: ""))
    }

    @Test("Fragmento de ±60 caracteres alrededor de la coincidencia")
    func snippet() throws {
        let long = String(repeating: "antes ", count: 30) + "la validación\nde stock " + String(repeating: "después ", count: 30)
        let snippet = try #require(HistoryExport.snippet(long, query: "validacion"))
        #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…"))
        #expect(snippet.contains("la validación de stock"))
        #expect(snippet.count <= 60 * 2 + "validación".count + 2)
        #expect(HistoryExport.snippet("corto", query: "corto") == "corto")
        #expect(HistoryExport.snippet("corto", query: "largo") == nil)
    }

    @Test("Separa los bloques de código del texto")
    func blocks() {
        let text = "Mirá:\n\n```swift\nlet x = 1\n\nprint(x)\n```\nY después:\n~~~\nsin lenguaje\n~~~\n```bash\nsin cerrar"
        #expect(HistoryExport.blocks(text) == [
            .prose("Mirá:"),
            .code(language: "swift", code: "let x = 1\n\nprint(x)"),
            .prose("Y después:"),
            .code(language: nil, code: "sin lenguaje"),
            .code(language: "bash", code: "sin cerrar"),
        ])
        #expect(HistoryExport.blocks("Solo **texto** con `código` en línea") == [.prose("Solo **texto** con `código` en línea")])
        #expect(HistoryExport.blocks("").isEmpty)
        #expect(HistoryExport.blocks("````md\n```\nadentro\n```\n````") == [.code(language: "md", code: "```\nadentro\n```")])
    }

    @Test("Separadores de día: Hoy, Ayer y la fecha")
    func days() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Argentina/Buenos_Aires")!
        let now = Date.reference // lunes 21 de septiembre de 2026, 11:13 en Buenos Aires
        let locale = Locale(identifier: "es")
        #expect(HistoryExport.dayLabel(now.addingTimeInterval(-3600), now: now, calendar: calendar, locale: locale) == "Hoy")
        #expect(HistoryExport.dayLabel(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale) == "Ayer")
        #expect(HistoryExport.dayLabel(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar, locale: locale) == "18 sept")
        #expect(HistoryExport.dayLabel(now.addingTimeInterval(-365 * 86_400), now: now, calendar: calendar, locale: locale) == "21 sept 2025")
    }

    @Test("Sin copia completa, la línea de tiempo es el registro de siempre")
    func timelineWithoutFull() {
        #expect(HistoryExport.timeline(log: entries, full: []) == entries)
    }
}
