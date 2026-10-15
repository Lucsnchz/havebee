import Foundation

/// Algo que el buscador (⌘K) puede hacer además de abrir un elemento.
public enum SwitcherAction: Equatable, Sendable {
    case newSession(branch: UUID, kind: SessionKind)
    case newBranch(project: UUID)
    case addProject
    case setLayout(compact: Bool)
    case settings
}

/// Un resultado del buscador rápido (⌘K).
public struct SwitcherItem: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case project(UUID)
        case branch(UUID)
        case session(UUID)
        case command(project: UUID, command: UUID)
        /// Una sesión archivada: al elegirla se ve su historial.
        case archivedSession(UUID)
        case action(SwitcherAction)
    }

    /// Tipo de resultado, para agruparlos bajo un encabezado.
    public enum Kind: Int, CaseIterable, Sendable {
        case session, branch, project, command, action, archived

        public var header: String {
            switch self {
            case .session: "Sesiones"
            case .branch: "Ramas"
            case .project: "Proyectos"
            case .command: "Comandos"
            case .action: "Acciones"
            case .archived: "Archivadas"
            }
        }
    }

    public let id: String
    public let target: Target
    public let title: String
    public let subtitle: String
    /// Texto donde se busca (título + contexto).
    public let haystack: String
    /// Para ordenar cuando no hay búsqueda.
    public let recency: Date

    public var kind: Kind {
        switch target {
        case .project: .project
        case .branch: .branch
        case .session: .session
        case .command: .command
        case .archivedSession: .archived
        case .action: .action
        }
    }
}

public enum SwitcherIndex {
    /// Con este prefijo («>nueva claude») el buscador muestra solo acciones.
    public static let actionPrefix: Character = ">"

    public static func items(_ projects: [Project], includeArchived: Bool = false) -> [SwitcherItem] {
        var items: [SwitcherItem] = []
        for project in projects {
            items.append(SwitcherItem(id: "p-\(project.id)", target: .project(project.id), title: project.name,
                                      subtitle: "Proyecto", haystack: project.name, recency: .distantPast))
            for branch in project.branches {
                let place = project.isScratch ? project.name : "\(project.name) › \(branch.name)"
                if !project.isScratch {
                    items.append(SwitcherItem(id: "b-\(branch.id)", target: .branch(branch.id), title: branch.name,
                                              subtitle: "Rama de \(project.name)", haystack: "\(branch.name) \(project.name)",
                                              recency: .distantPast))
                }
                for session in branch.activeSessions {
                    items.append(SwitcherItem(id: "s-\(session.id)", target: .session(session.id), title: session.name,
                                              subtitle: place,
                                              haystack: "\(session.name) \(session.kind.label) \(branch.name) \(project.name)",
                                              recency: session.recency))
                }
                if includeArchived {
                    for session in branch.archivedSessions {
                        items.append(SwitcherItem(id: "a-\(session.id)", target: .archivedSession(session.id), title: session.name,
                                                  subtitle: "Archivada · \(place)",
                                                  haystack: "\(session.name) \(session.kind.label) \(branch.name) \(project.name) archivada",
                                                  recency: session.archivedAt ?? session.recency))
                    }
                }
            }
            for command in project.commands {
                items.append(SwitcherItem(id: "c-\(command.id)", target: .command(project: project.id, command: command.id),
                                          title: "Ejecutar \(command.name)", subtitle: "\(project.name) · \(command.command)",
                                          haystack: "ejecutar correr \(command.name) \(command.command) \(project.name)",
                                          recency: .distantPast))
            }
        }
        return items
    }

    /// Lo que se puede hacer desde el buscador: sesiones nuevas en cada rama, ramas nuevas,
    /// agregar proyectos, cambiar de vista y abrir los ajustes.
    public static func actions(projects: [Project], compactLayout: Bool = false) -> [SwitcherItem] {
        var items: [SwitcherItem] = [
            SwitcherItem(id: "x-add-project", target: .action(.addProject), title: "Agregar proyecto…",
                         subtitle: "Elegí la carpeta de un repo de git",
                         haystack: "agregar proyecto repo repositorio carpeta abrir sumar", recency: .distantPast),
            SwitcherItem(id: "x-layout", target: .action(.setLayout(compact: !compactLayout)),
                         title: compactLayout ? "Cambiar a vista de árbol" : "Cambiar a vista compacta",
                         subtitle: compactLayout ? "Proyectos, ramas y sesiones en la barra lateral" : "Proyectos en una barra angosta y sesiones como pestañas",
                         haystack: "cambiar vista layout compacta arbol pestañas barra lateral sidebar", recency: .distantPast),
            SwitcherItem(id: "x-settings", target: .action(.settings), title: "Ajustes…",
                         subtitle: "Terminal, avisos, editor e historial",
                         haystack: "ajustes preferencias configuracion opciones settings", recency: .distantPast),
        ]
        for project in projects {
            if !project.isScratch {
                items.append(SwitcherItem(id: "x-branch-\(project.id)", target: .action(.newBranch(project: project.id)),
                                          title: "Nueva rama en \(project.name)…", subtitle: "Worktree propio o carpeta principal",
                                          haystack: "nueva rama crear branch worktree \(project.name)", recency: .distantPast))
            }
            for branch in project.branches {
                let place = project.isScratch ? project.name : "\(project.name) › \(branch.name)"
                let recency = branch.activeSessions.map(\.recency).max() ?? .distantPast
                for kind in SessionKind.allCases {
                    items.append(SwitcherItem(
                        id: "x-new-\(branch.id)-\(kind.rawValue)", target: .action(.newSession(branch: branch.id, kind: kind)),
                        title: "Nueva sesión de \(kind.label) en \(place)", subtitle: kind.isAgent ? "Agente nuevo en esa carpeta" : "Tu shell en esa carpeta",
                        haystack: "nueva sesion crear abrir \(kind.label) \(kind.defaultName) \(kind.binary ?? "shell") \(branch.name) \(project.name)",
                        recency: recency))
                }
            }
        }
        return items
    }

    /// Busca en proyectos, ramas, sesiones y comandos. Con `includeArchived` suma las sesiones
    /// archivadas (siempre al final). Con `includeActions` suma las acciones cuyo título empieza
    /// con lo que escribiste; con el prefijo «>» muestra solo acciones.
    public static func search(_ query: String, in projects: [Project], limit: Int = 40,
                              includeArchived: Bool = false, includeActions: Bool = false,
                              compactLayout: Bool = false) -> [SwitcherItem] {
        let parsed = parse(query)
        if parsed.actionsOnly {
            return rank(parsed.text, actions(projects: projects, compactLayout: compactLayout), limit: limit, minimumScore: 0)
        }
        let all = items(projects, includeArchived: includeArchived)
        let q = parsed.text
        guard !q.isEmpty else {
            // Sin búsqueda: las sesiones usadas más recientemente y después los proyectos.
            let sessions = all.filter { $0.kind == .session }
                .sorted { $0.recency > $1.recency }
                .prefix(8)
            let projects = all.filter { $0.kind == .project }
            return Array(sessions) + projects
        }
        var results = rank(q, all, limit: limit, minimumScore: 0)
        if includeActions {
            // Sin «>», solo las acciones cuyo título empieza así («nueva…», «ajus…»): si no,
            // escribir el nombre de un proyecto llenaría la lista de «Nueva sesión en…».
            let actions = rank(q, actions(projects: projects, compactLayout: compactLayout), limit: limit, minimumScore: 100)
            let archivedStart = results.firstIndex { $0.kind == .archived } ?? results.endIndex
            results.insert(contentsOf: actions, at: archivedStart)
            results = Array(results.prefix(limit))
        }
        return results
    }

    /// Partes del título que coinciden con la búsqueda (en caracteres), para resaltarlas. Sigue
    /// el mismo criterio que el puntaje: el texto seguido (mejor si empieza una palabra), cada
    /// palabra por separado o, como último recurso, las letras en orden.
    public static func highlights(_ query: String, in title: String) -> [Range<Int>] {
        let q = Array(parse(query).text)
        guard !q.isEmpty else { return [] }
        // Título normalizado letra por letra, recordando de qué carácter original viene cada una.
        var folded: [Character] = []
        var origin: [Int] = []
        for (index, char) in title.enumerated() {
            for piece in normalize(String(char)) {
                folded.append(piece)
                origin.append(index)
            }
        }
        func span(_ start: Int, _ length: Int) -> Range<Int> { origin[start]..<(origin[start + length - 1] + 1) }

        if let start = occurrence(of: q, in: folded) { return [span(start, q.count)] }
        let words = q.split(separator: " ").map(Array.init)
        if words.count > 1 {
            var ranges: [Range<Int>] = []
            for word in words {
                guard let start = occurrence(of: word, in: folded) else { ranges = []; break }
                ranges.append(span(start, word.count))
            }
            if !ranges.isEmpty { return merge(ranges) }
        }
        var ranges: [Range<Int>] = []
        var next = q.startIndex
        for (position, char) in folded.enumerated() where next < q.endIndex && q[next] == char {
            ranges.append(span(position, 1))
            next += 1
        }
        return next == q.endIndex ? merge(ranges) : []
    }

    /// Prefijo del título > comienzo de palabra > contiene > todas las palabras > letras en orden.
    static func score(_ q: String, title: String, haystack: String) -> Int? {
        if title.hasPrefix(q) { return 100 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 80 }
        if title.contains(q) { return 60 }
        if haystack.contains(q) { return 40 }
        let words = q.split(separator: " ")
        if words.count > 1 && words.allSatisfy({ haystack.contains($0) }) { return 30 }
        var rest = Substring(q)
        for char in haystack where rest.first == char { rest = rest.dropFirst() }
        return rest.isEmpty ? 10 : nil
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
    }

    /// Separa el prefijo de acciones y normaliza el resto.
    static func parse(_ query: String) -> (actionsOnly: Bool, text: String) {
        var text = query.trimmingCharacters(in: .whitespaces)
        let actionsOnly = text.first == actionPrefix
        if actionsOnly { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return (actionsOnly, normalize(text))
    }

    /// Ordena por puntaje (las archivadas, con menos) y, si empatan, por uso reciente.
    private static func rank(_ q: String, _ items: [SwitcherItem], limit: Int, minimumScore: Int) -> [SwitcherItem] {
        guard !q.isEmpty else { return Array(items.prefix(limit)) }
        var scored: [(item: SwitcherItem, score: Int)] = []
        for item in items {
            guard let value = score(q, title: normalize(item.title), haystack: normalize(item.haystack)), value >= minimumScore else { continue }
            scored.append((item, item.kind == .archived ? value - 1_000 : value))
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.item.recency > b.item.recency }
        return scored.prefix(limit).map(\.item)
    }

    /// Dónde aparece `needle`: mejor al comienzo de una palabra; si no, la primera vez.
    private static func occurrence(of needle: [Character], in text: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= text.count else { return nil }
        var first: Int?
        for start in 0...(text.count - needle.count) where text[start..<(start + needle.count)].elementsEqual(needle) {
            if start == 0 || !(text[start - 1].isLetter || text[start - 1].isNumber) { return start }
            if first == nil { first = start }
        }
        return first
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
