import Foundation
import Testing
@testable import HiveCore

@Suite("Buscador rápido: «?» busca en el historial")
struct SwitcherHistoryTests {
    let claude = Session(name: "Claude 1", kind: .claude, lastActivityAt: .reference)
    let archived = Session(name: "Claude viejo", kind: .claude, archivedAt: .reference)
    let codex = Session(name: "Codex pedidos", kind: .codex)
    let shell = Session(name: "Terminal 1", kind: .shell)
    let gemini = Session(name: "Gemini", kind: .gemini)
    var projects: [Project] {
        var scratch = Project.scratch(home: "/h")
        scratch.branches[0].sessions = [shell]
        return [Project(name: "ecommerce", path: "/e", branches: [
            Branch(name: "main", mode: .main, sessions: [claude, archived, gemini]),
            Branch(name: "SEGURIDAD", mode: .worktree, worktreePath: "/s", sessions: [codex]),
        ]), scratch]
    }

    @Test("El prefijo «?» separa lo que hay que buscar")
    func prefix() {
        #expect(SwitcherIndex.historyQuery("?migración") == "migración")
        #expect(SwitcherIndex.historyQuery("  ?  validación de stock ") == "validación de stock")
        #expect(SwitcherIndex.historyQuery("?") == "")
        #expect(SwitcherIndex.historyQuery("migración") == nil)
        #expect(SwitcherIndex.historyQuery(">nueva") == nil)
        // La búsqueda común no muestra nada con «?»: la del historial la hace la vista.
        #expect(SwitcherIndex.search("?claude", in: projects, includeArchived: true, includeActions: true).isEmpty)
        // El resaltado ignora el prefijo.
        #expect(SwitcherIndex.highlights("?stock", in: "validación de stock") == [14..<19])
    }

    @Test("El botón del panel de historial escribe la búsqueda con «?» adelante")
    func historySearch() {
        #expect(SwitcherIndex.historySearch("validación") == "?validación")
        #expect(SwitcherIndex.historySearch("  validación de stock \n") == "?validación de stock")
        #expect(SwitcherIndex.historySearch("") == "?") // sin nada escrito, ⌘K muestra la ayuda del historial
        for text in ["migración", "stock al checkout", ""] {
            #expect(SwitcherIndex.historyQuery(SwitcherIndex.historySearch(text)) == text)
        }
    }

    @Test("Las filas del historial no muestran las marcas de Markdown", arguments: [
        ("## Listo Agregué la **validación** de stock: - Si no alcanza, tira `OutOfStock`. - Los 12 tests pasan.",
         "Listo Agregué la validación de stock: • Si no alcanza, tira OutOfStock. • Los 12 tests pasan."),
        ("…cambié el ```php if ($item->stock < $qty) { ``` y listo", "…cambié el if ($item->stock < $qty) { y listo"),
        ("…y después * otra viñeta", "…y después • otra viñeta"),
        // Lo que no es Markdown queda igual.
        ("Llegó un rate_limit en __construct", "Llegó un rate_limit en __construct"),
        ("Arreglá el issue #123 en src/**/*.php", "Arreglá el issue #123 en src/**/*.php"),
        ("Agregá validación de stock", "Agregá validación de stock"),
    ])
    func withoutMarkdown(snippet: String, expected: String) {
        #expect(HistoryExport.withoutMarkdown(snippet) == expected)
    }

    @Test("Busca en las sesiones de Claude y Codex, también las archivadas")
    func sessionIds() {
        let ids = SwitcherIndex.historySessionIds(projects)
        #expect(Set(ids) == [claude.id, archived.id, codex.id])
    }

    @Test("Cada mensaje encontrado es una fila con quién, dónde y cuándo")
    func items() throws {
        let now = Date.reference
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let hits = [
            HistoryStore.SearchHit(sessionId: claude.id, entryId: UUID(), role: .user, date: now,
                                   snippet: "Agregá validación de stock al checkout"),
            HistoryStore.SearchHit(sessionId: codex.id, entryId: UUID(), role: .assistant, date: now.addingTimeInterval(-86_400),
                                   snippet: "Corrí la migración de pedidos"),
            HistoryStore.SearchHit(sessionId: archived.id, entryId: UUID(), role: .system, date: now,
                                   snippet: "Tarea en segundo plano: stock"),
            HistoryStore.SearchHit(sessionId: UUID(), entryId: UUID(), role: .user, date: now, snippet: "De una sesión borrada"),
        ]
        let items = SwitcherIndex.historyItems(hits, query: "stock", in: projects, now: now, calendar: calendar)
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.kind == .history })
        #expect(items[0].title == "Agregá validación de stock al checkout")
        #expect(items[0].subtitle == "Vos · Claude 1 · ecommerce › main · Hoy")
        #expect(items[1].subtitle == "Codex · Codex pedidos · ecommerce › SEGURIDAD · Ayer")
        #expect(items[2].subtitle == "Automático · Claude viejo (archivada) · ecommerce › main · Hoy")
        guard case .historyEntry(let session, let entry) = items[0].target else {
            Issue.record("Debería abrir la entrada del historial")
            return
        }
        #expect(session == claude.id)
        #expect(entry == hits[0].entryId)
        #expect(SwitcherItem.Kind.history.header == "Historial")
    }

    @Test("Un mensaje largo se recorta alrededor de lo que buscaste")
    func longSnippet() {
        let long = String(repeating: "antes ", count: 30) + "migración" + String(repeating: " después", count: 30)
        let hit = HistoryStore.SearchHit(sessionId: claude.id, entryId: UUID(), role: .assistant, date: .reference, snippet: long)
        let title = SwitcherIndex.historyItems([hit], query: "migracion", in: projects).first?.title ?? ""
        #expect(title.contains("migración"))
        #expect(title.count < 90)
        #expect(title.hasPrefix("…") && title.hasSuffix("…"))
    }

    @Test("La fila de un mensaje con Markdown se lee limpia y con la coincidencia marcada")
    func markdownTitle() throws {
        let hit = HistoryStore.SearchHit(sessionId: claude.id, entryId: UUID(), role: .assistant, date: .reference,
                                         snippet: "## Listo Agregué la **validación** de stock: - Si no alcanza, tira `OutOfStock`.")
        let title = try #require(SwitcherIndex.historyItems([hit], query: "validacion", in: projects).first?.title)
        #expect(!title.contains("**") && !title.contains("##") && !title.contains("`"))
        #expect(title.contains("Agregué la validación de stock"))
        let range = try #require(SwitcherIndex.highlights("?validacion", in: title).first)
        let start = title.index(title.startIndex, offsetBy: range.lowerBound)
        let end = title.index(title.startIndex, offsetBy: range.upperBound)
        #expect(title[start..<end] == "validación")
    }

    @Test("De punta a punta: lo guardado en el historial aparece como resultado")
    func endToEnd() {
        let dir = TempDir()
        let history = HistoryStore(directory: dir.url)
        history.append(HistoryEntry(date: .reference, role: .user, text: "Corré la migración de pedidos"), sessionId: claude.id, agentName: "Claude")
        history.append(HistoryEntry(date: .reference, role: .assistant, text: "Listo, la migración pasó."), sessionId: claude.id, agentName: "Claude")
        history.append(HistoryEntry(date: .reference, role: .user, text: "Nada que ver"), sessionId: codex.id, agentName: "Codex")
        let query = SwitcherIndex.historyQuery("?migracion") ?? ""
        let hits = history.search(query, sessionIds: SwitcherIndex.historySessionIds(projects), limit: 30)
        let items = SwitcherIndex.historyItems(hits, query: query, in: projects)
        #expect(items.count == 2)
        #expect(Set(items.map(\.title)) == ["Corré la migración de pedidos", "Listo, la migración pasó."])
    }
}
