import Foundation

/// Consultas y cambios sobre la lista de proyectos. Todo es puro: el store solo los aplica.
extension Array where Element == Project {
    public var repos: [Project] { filter { !$0.isScratch } }
    public var scratch: Project? { first(where: \.isScratch) }

    public func project(_ id: UUID) -> Project? {
        first { $0.id == id }
    }

    public func branchContext(_ id: UUID) -> (project: Project, branch: Branch)? {
        for p in self {
            if let b = p.branches.first(where: { $0.id == id }) { return (p, b) }
        }
        return nil
    }

    public func sessionContext(_ id: UUID) -> (project: Project, branch: Branch, session: Session)? {
        for p in self {
            for b in p.branches {
                if let s = b.sessions.first(where: { $0.id == id }) { return (p, b, s) }
            }
        }
        return nil
    }

    /// Proyecto al que pertenece un elemento del sidebar.
    public func projectId(of item: SidebarItem?) -> UUID? {
        switch item {
        case .project(let id)?: project(id)?.id
        case .branch(let id)?: branchContext(id)?.project.id
        case .session(let id)?: sessionContext(id)?.project.id
        case nil: nil
        }
    }

    public func contains(_ item: SidebarItem?, inProject projectId: UUID) -> Bool {
        self.projectId(of: item) == projectId
    }

    /// IDs de conversación de agentes de un tipo ya usados por otras sesiones.
    public func claimedAgentIds(_ kind: SessionKind, except sessionId: UUID) -> Set<String> {
        Set(flatMap(\.allSessions).filter { $0.kind == kind && $0.id != sessionId }.compactMap(\.agentSessionId))
    }

    // MARK: Cambios

    @discardableResult
    public mutating func updateProject(_ id: UUID, _ body: (inout Project) -> Void) -> Bool {
        guard let i = firstIndex(where: { $0.id == id }) else { return false }
        body(&self[i])
        return true
    }

    @discardableResult
    public mutating func updateBranch(_ id: UUID, _ body: (inout Branch) -> Void) -> Bool {
        for pi in indices {
            if let bi = self[pi].branches.firstIndex(where: { $0.id == id }) {
                body(&self[pi].branches[bi])
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func updateSession(_ id: UUID, _ body: (inout Session) -> Void) -> Bool {
        for pi in indices {
            for bi in self[pi].branches.indices {
                if let si = self[pi].branches[bi].sessions.firstIndex(where: { $0.id == id }) {
                    body(&self[pi].branches[bi].sessions[si])
                    return true
                }
            }
        }
        return false
    }

    /// Agrega un repo antes de «Terminales», que siempre queda último.
    public mutating func insertRepo(_ project: Project) {
        insert(project, at: firstIndex(where: \.isScratch) ?? endIndex)
    }

    /// Crea «Terminales» si no existe y lo deja último.
    public mutating func ensureScratch(home: String) {
        if let index = firstIndex(where: \.isScratch) {
            if index != count - 1 { append(remove(at: index)) }
            return
        }
        append(.scratch(home: home))
    }

    // MARK: Orden

    /// Mueve repos (los índices son de la lista sin «Terminales», como la muestra el sidebar).
    public mutating func moveRepos(fromOffsets source: IndexSet, toOffset destination: Int) {
        var repos = self.repos
        repos.moveItems(fromOffsets: source, toOffset: destination)
        self = repos + (scratch.map { [$0] } ?? [])
    }

    /// Posición de un elemento entre sus hermanos visibles: (índice, cantidad).
    public func position(of item: SidebarItem) -> (index: Int, count: Int)? {
        switch item {
        case .project(let id):
            let repos = self.repos
            return repos.firstIndex { $0.id == id }.map { ($0, repos.count) }
        case .branch(let id):
            guard let ctx = branchContext(id) else { return nil }
            return ctx.project.branches.firstIndex { $0.id == id }.map { ($0, ctx.project.branches.count) }
        case .session(let id):
            guard let ctx = sessionContext(id) else { return nil }
            let active = ctx.branch.activeSessions
            return active.firstIndex { $0.id == id }.map { ($0, active.count) }
        }
    }

    /// Sube (-1) o baja (+1) un elemento un lugar entre sus hermanos. Devuelve si se movió.
    @discardableResult
    public mutating func move(_ item: SidebarItem, by delta: Int) -> Bool {
        guard let (index, count) = position(of: item) else { return false }
        let target = index + delta
        guard target >= 0, target < count else { return false }
        let destination = delta > 0 ? target + 1 : target
        switch item {
        case .project:
            moveRepos(fromOffsets: [index], toOffset: destination)
        case .branch(let id):
            guard let ctx = branchContext(id) else { return false }
            updateProject(ctx.project.id) { $0.branches.moveItems(fromOffsets: [index], toOffset: destination) }
        case .session(let id):
            guard let ctx = sessionContext(id) else { return false }
            updateBranch(ctx.branch.id) { $0.moveActiveSessions(fromOffsets: [index], toOffset: destination) }
        }
        return true
    }
}

extension Branch {
    /// Mueve sesiones visibles; las archivadas quedan al final.
    public mutating func moveActiveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        var active = activeSessions
        active.moveItems(fromOffsets: source, toOffset: destination)
        sessions = active + archivedSessions
    }

    /// Siguiente nombre libre para una sesión nueva de un tipo ("Claude 3").
    public func nextSessionName(for kind: SessionKind) -> String {
        let names = Set(sessions.map(\.name))
        var n = sessions.filter { $0.kind == kind }.count + 1
        while names.contains("\(kind.defaultName) \(n)") { n += 1 }
        return "\(kind.defaultName) \(n)"
    }
}

extension Project {
    /// La pestaña de al lado de una sesión: la siguiente, o la anterior si era la última.
    public func neighborSession(of id: UUID) -> UUID? {
        let active = activeSessions
        guard let index = active.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < active.count { return active[index + 1].id }
        if index > 0 { return active[index - 1].id }
        return nil
    }

    /// Sesión para abrir al elegir el proyecto: la última abierta, o la usada más recientemente.
    public func sessionToOpen(last: UUID?) -> UUID? {
        let sessions = activeSessions
        if let last, sessions.contains(where: { $0.id == last }) { return last }
        return sessions.max { $0.recency < $1.recency }?.id
    }

    /// Una rama en la carpeta principal solo está activa si es la que tiene checkout.
    public func isActive(_ branch: Branch, head: String?) -> Bool {
        branch.mode == .worktree || isScratch || head == branch.name
    }

    /// Rama por defecto: la que tiene checkout la carpeta principal, o la primera.
    public func mainBranch(head: String?) -> Branch? {
        branches.first { $0.mode == .main && $0.name == head } ?? branches.first
    }
}

extension Array {
    /// Igual que `move(fromOffsets:toOffset:)` de SwiftUI, para usarlo fuera de las vistas.
    public mutating func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { indices.contains($0) }
        let moving = valid.map { self[$0] }
        let target = destination - valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) { remove(at: index) }
        insert(contentsOf: moving, at: Swift.min(Swift.max(target, 0), count))
    }
}
