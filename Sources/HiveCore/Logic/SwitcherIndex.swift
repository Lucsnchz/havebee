import Foundation

/// Un resultado del buscador rápido (⌘K).
public struct SwitcherItem: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case project(UUID)
        case branch(UUID)
        case session(UUID)
        case command(project: UUID, command: UUID)
    }

    public let id: String
    public let target: Target
    public let title: String
    public let subtitle: String
    /// Texto donde se busca (título + contexto).
    public let haystack: String
    /// Para ordenar cuando no hay búsqueda.
    public let recency: Date
}

public enum SwitcherIndex {
    public static func items(_ projects: [Project]) -> [SwitcherItem] {
        var items: [SwitcherItem] = []
        for project in projects {
            items.append(SwitcherItem(id: "p-\(project.id)", target: .project(project.id), title: project.name,
                                      subtitle: "Proyecto", haystack: project.name, recency: .distantPast))
            for branch in project.branches {
                if !project.isScratch {
                    items.append(SwitcherItem(id: "b-\(branch.id)", target: .branch(branch.id), title: branch.name,
                                              subtitle: "Rama de \(project.name)", haystack: "\(branch.name) \(project.name)",
                                              recency: .distantPast))
                }
                for session in branch.activeSessions {
                    items.append(SwitcherItem(id: "s-\(session.id)", target: .session(session.id), title: session.name,
                                              subtitle: project.isScratch ? project.name : "\(project.name) › \(branch.name)",
                                              haystack: "\(session.name) \(session.kind.label) \(branch.name) \(project.name)",
                                              recency: session.recency))
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

    public static func search(_ query: String, in projects: [Project], limit: Int = 40) -> [SwitcherItem] {
        let all = items(projects)
        let q = normalize(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else {
            // Sin búsqueda: las sesiones usadas más recientemente y después los proyectos.
            let sessions = all.filter { if case .session = $0.target { return true }; return false }
                .sorted { $0.recency > $1.recency }
                .prefix(8)
            let projects = all.filter { if case .project = $0.target { return true }; return false }
            return Array(sessions) + projects
        }
        var scored: [(item: SwitcherItem, score: Int)] = []
        for item in all {
            if let value = score(q, title: normalize(item.title), haystack: normalize(item.haystack)) {
                scored.append((item, value))
            }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.item.recency > b.item.recency }
        return scored.prefix(limit).map(\.item)
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
}
