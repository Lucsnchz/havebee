import Foundation

/// El orden de los proyectos, el mismo en el riel de la vista compacta, en el árbol y en ⌃⌘1…⌃⌘9:
///
/// 1. Los fijados (clic derecho › «Fijar arriba»), estén activos o no.
/// 2. Los activos: con algo prendido (una sesión corriendo o esperándote, un comando corriendo) o
///    con alguna sesión usada hoy.
/// 3. Los apagados: sin nada prendido ni usado en el día.
/// 4. «Terminales», siempre al final.
///
/// Dentro de cada grupo manda el orden manual (el de la lista guardada), no el último uso: así un
/// proyecto no salta de lugar cada vez que lo tocás. Cuando cambiás el orden (arrastrando, con
/// «Subir» y «Bajar» o fijando), lo que se guarda como orden manual es el orden que se ve.
public struct ProjectOrdering: Sendable {
    /// En qué grupo cae un proyecto. Los casos están en el orden de la lista.
    public enum Group: Int, CaseIterable, Sendable {
        case pinned, active, idle, scratch
    }

    /// Un proyecto en su lugar de la lista.
    public struct Item: Identifiable, Equatable, Sendable {
        public let project: Project
        public let group: Group
        /// Tiene algo prendido o se usó hoy. Los que no (los apagados y los fijados sin actividad)
        /// se ven atenuados.
        public let isActive: Bool

        public var id: UUID { project.id }

        public init(project: Project, group: Group, isActive: Bool) {
            self.project = project
            self.group = group
            self.isActive = isActive
        }
    }

    /// «Ahora», para saber qué se usó hoy.
    public var now: Date
    /// El calendario (con su zona horaria) que dice dónde empieza y termina el día.
    public var calendar: Calendar
    /// Sesiones prendidas: corriendo o con algo que mostrarte (permiso, turno sin ver).
    public var liveSessions: Set<UUID>
    /// Proyectos con un comando corriendo (ej. `npm run dev`).
    public var busyProjects: Set<UUID>

    public init(now: Date, calendar: Calendar, liveSessions: Set<UUID> = [], busyProjects: Set<UUID> = []) {
        self.now = now
        self.calendar = calendar
        self.liveSessions = liveSessions
        self.busyProjects = busyProjects
    }

    // MARK: Grupos

    /// Si el proyecto tiene algo prendido o alguna sesión (no archivada) usada en el día de hoy.
    /// Una sesión corriendo cuenta aunque se haya usado por última vez hace días.
    public func isActive(_ project: Project) -> Bool {
        if busyProjects.contains(project.id) { return true }
        return project.activeSessions.contains { session in
            liveSessions.contains(session.id) || calendar.isDate(session.recency, inSameDayAs: now)
        }
    }

    public func group(of project: Project) -> Group {
        if project.isScratch { return .scratch }
        if project.pinned { return .pinned }
        return isActive(project) ? .active : .idle
    }

    /// Los proyectos en el orden en que se ven.
    public func arrange(_ projects: [Project]) -> [Item] {
        let items = projects.map { Item(project: $0, group: group(of: $0), isActive: isActive($0)) }
        return Group.allCases.flatMap { group in items.filter { $0.group == group } }
    }

    /// Los proyectos de cada grupo, en el orden en que se ven (uno por caso de `Group`).
    private func sections(_ projects: [Project]) -> [[Project]] {
        let items = arrange(projects)
        return Group.allCases.map { group in items.filter { $0.group == group }.map(\.project) }
    }

    // MARK: Cambios de orden

    /// Mueve proyectos dentro de su grupo (los índices son de la lista del grupo, como los da
    /// `onMove`). Devuelve la lista nueva: el orden que se ve, con el cambio. Un proyecto no cambia
    /// de grupo por moverlo.
    public func moving(_ projects: [Project], in group: Group, fromOffsets source: IndexSet, toOffset destination: Int) -> [Project] {
        var sections = sections(projects)
        sections[group.rawValue].moveItems(fromOffsets: source, toOffset: destination)
        return sections.flatMap { $0 }
    }

    /// Posición de un proyecto entre los de su grupo: (índice, cantidad).
    public func position(of id: UUID, in projects: [Project]) -> (index: Int, count: Int)? {
        for section in sections(projects) {
            if let index = section.firstIndex(where: { $0.id == id }) { return (index, section.count) }
        }
        return nil
    }

    /// Sube (-1) o baja (+1) un proyecto un lugar dentro de su grupo. nil si ya está en el borde.
    public func moving(_ projects: [Project], id: UUID, by delta: Int) -> [Project]? {
        guard let project = projects.first(where: { $0.id == id }), let (index, count) = position(of: id, in: projects) else {
            return nil
        }
        let target = index + delta
        guard target >= 0, target < count else { return nil }
        return moving(projects, in: group(of: project), fromOffsets: [index], toOffset: delta > 0 ? target + 1 : target)
    }

    /// Arrastrar un proyecto sobre otro (el riel): toma su lugar, si son del mismo grupo. Si venía
    /// de arriba queda abajo del otro, y al revés. nil si no hay nada que mover.
    public func moving(_ projects: [Project], dragging id: UUID, onto target: UUID) -> [Project]? {
        guard id != target, let dragged = projects.first(where: { $0.id == id }),
              let destination = projects.first(where: { $0.id == target }) else { return nil }
        let group = group(of: dragged)
        guard group == self.group(of: destination), group != .scratch,
              let (from, _) = position(of: id, in: projects), let (to, _) = position(of: target, in: projects) else { return nil }
        return moving(projects, in: group, fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    /// Fija o desfija un proyecto. Al fijarlo queda último entre los fijados (justo arriba del
    /// divisor); al desfijarlo, primero de su grupo, pegado a donde estaba. «Terminales» no se fija.
    public func pinning(_ projects: [Project], id: UUID, pinned: Bool) -> [Project] {
        var visible = arrange(projects).map(\.project)
        guard let index = visible.firstIndex(where: { $0.id == id }), !visible[index].isScratch else { return projects }
        var project = visible.remove(at: index)
        project.pinned = pinned
        let boundary = visible.filter { $0.pinned && !$0.isScratch }.count
        visible.insert(project, at: boundary)
        return visible
    }
}
