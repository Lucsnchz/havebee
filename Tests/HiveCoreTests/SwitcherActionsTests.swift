import Foundation
import Testing
@testable import HiveCore

@Suite("Buscador rápido: acciones, archivadas y resaltado")
struct SwitcherActionsTests {
    let main: Branch
    let seguridad: Branch
    let projects: [Project]

    init() {
        let active = Session(name: "Claude 1", kind: .claude, lastActivityAt: .reference)
        let archived = Session(name: "Claude viejo", kind: .claude, lastActivityAt: .reference, archivedAt: .reference)
        let codex = Session(name: "Codex pedidos", kind: .codex, lastActivityAt: .reference.addingTimeInterval(100))
        main = Branch(name: "main", mode: .main, sessions: [active, archived])
        seguridad = Branch(name: "SEGURIDAD", mode: .worktree, worktreePath: "/s", sessions: [codex])
        projects = [Project(name: "ecommerce", path: "/e", branches: [main, seguridad]), .scratch(home: "/h")]
    }

    func titles(_ query: String, archived: Bool = false, actions: Bool = false) -> [String] {
        SwitcherIndex.search(query, in: projects, includeArchived: archived, includeActions: actions).map(\.title)
    }

    @Test("Las archivadas solo aparecen si se piden, con su lugar y al final")
    func archived() throws {
        #expect(!titles("claude").contains("Claude viejo"))
        let results = SwitcherIndex.search("claude", in: projects, includeArchived: true)
        #expect(results.map(\.title).last == "Claude viejo")
        #expect(results.map(\.title).first == "Claude 1")
        let item = try #require(results.last)
        #expect(item.subtitle == "Archivada · ecommerce › main")
        #expect(item.kind == .archived)
        guard case .archivedSession = item.target else {
            Issue.record("Debería abrir el historial de la archivada")
            return
        }
        // Aunque coincida mejor (prefijo del título), queda detrás de las activas que coinciden peor.
        #expect(titles("claude v", archived: true) == ["Claude viejo"])
        let worse = SwitcherIndex.search("c", in: projects, includeArchived: true)
        #expect(worse.last?.title == "Claude viejo")
    }

    @Test("Sin búsqueda no muestra archivadas ni acciones")
    func emptyQuery() {
        let results = SwitcherIndex.search("", in: projects, includeArchived: true, includeActions: true)
        #expect(results.allSatisfy { $0.kind == .session || $0.kind == .project })
    }

    @Test("Con «>» muestra solo acciones")
    func actionPrefix() {
        let results = SwitcherIndex.search(">nueva claude", in: projects)
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.kind == .action })
        #expect(results.first?.title.hasPrefix("Nueva sesión de Claude Code en ") == true)
        #expect(results.map(\.title).contains("Nueva sesión de Claude Code en ecommerce › SEGURIDAD"))
        #expect(results.map(\.title).contains("Nueva sesión de Claude Code en Terminales"))
        // La rama usada más recientemente primero.
        #expect(results.first?.title == "Nueva sesión de Claude Code en ecommerce › SEGURIDAD")
        let everything = SwitcherIndex.search(">", in: projects)
        #expect(everything.map(\.title).prefix(3) == ["Agregar proyecto…", "Cambiar a vista compacta", "Ajustes…"])
        #expect(SwitcherIndex.search("> ajustes", in: projects).first?.target == .action(.settings))
        // Letras sueltas en orden: tienen que estar en el título, no en cualquier parte del contexto.
        #expect(SwitcherIndex.search(">ajst", in: projects).map(\.title) == ["Ajustes…"])
        #expect(!SwitcherIndex.search(">nueva claude", in: projects).contains { $0.title.contains("Terminal en") })
    }

    @Test("Las acciones de cada proyecto y rama")
    func actionList() {
        let actions = SwitcherIndex.actions(projects: projects)
        let titles = actions.map(\.title)
        #expect(titles.contains("Nueva rama en ecommerce…"))
        #expect(!titles.contains("Nueva rama en Terminales…"))
        for kind in SessionKind.allCases {
            #expect(titles.contains("Nueva sesión de \(kind.label) en ecommerce › main"))
        }
        #expect(actions.first { $0.title == "Nueva sesión de Codex en ecommerce › main" }?.target
            == .action(.newSession(branch: main.id, kind: .codex)))
        #expect(actions.contains { $0.target == .action(.setLayout(compact: true)) })
        let compact = SwitcherIndex.actions(projects: projects, compactLayout: true)
        #expect(compact.first { $0.target == .action(.setLayout(compact: false)) }?.title == "Cambiar a vista de árbol")
        #expect(Set(actions.map(\.id)).count == actions.count)
    }

    @Test("Sin «>», solo las acciones cuyo título empieza con lo escrito")
    func actionsWithoutPrefix() {
        #expect(titles("ajus", actions: true) == ["Ajustes…"])
        #expect(!titles("eco", actions: true).contains { $0.hasPrefix("Nueva") })
        #expect(titles("nueva", actions: true).contains("Nueva rama en ecommerce…"))
        #expect(titles("nueva").isEmpty) // por defecto, sin acciones
        // Las acciones van antes de las archivadas.
        let mixed = SwitcherIndex.search("c", in: projects, includeArchived: true, includeActions: true)
        #expect(mixed.last?.kind == .archived)
        #expect(mixed.contains { $0.kind == .action })
    }

    @Test("Encabezados por tipo")
    func headers() {
        #expect(SwitcherItem.Kind.allCases.map(\.header) == ["Sesiones", "Ramas", "Proyectos", "Comandos", "Acciones", "Archivadas"])
    }

    @Test("Resalta lo que coincide", arguments: [
        ("eco", "ecommerce", [0..<3]),
        ("pedidos", "Codex pedidos", [6..<13]),
        ("BEVO", "Bevó", [0..<4]),
        ("main", "domain main", [7..<11]),
        ("main", "domain", [2..<6]),
        (">nueva claude", "Nueva sesión de Claude Code en ecommerce › main", [0..<5, 16..<22]),
        ("cdxpdd", "Codex pedidos", [0..<1, 2..<3, 4..<5, 6..<7, 8..<9, 10..<11]),
        ("dex ped", "Codex pedidos", [2..<9]),
        ("zzz", "Codex pedidos", []),
        ("", "Codex pedidos", []),
    ])
    func highlights(query: String, title: String, expected: [Range<Int>]) {
        #expect(SwitcherIndex.highlights(query, in: title) == expected)
    }
}
