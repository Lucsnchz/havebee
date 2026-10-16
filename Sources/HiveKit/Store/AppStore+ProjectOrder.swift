import AppKit
import HiveCore

/// El orden de los proyectos que comparten el riel, el árbol y ⌃⌘1…⌃⌘9 (lo decide
/// `ProjectOrdering`): fijados, activos de hoy, apagados y «Terminales».
extension AppStore {
    /// Las reglas del orden con lo que está pasando ahora: qué está prendido y qué día es.
    var projectOrdering: ProjectOrdering {
        // Se lee para que las vistas se vuelvan a dibujar cuando cambia el día.
        _ = dayStamp
        // Prendida: corriendo, o con algo que mostrarte aunque el proceso ya haya terminado.
        let live = runtimes.values.filter { $0.isRunning || $0.unseen || $0.status == .attention }.map(\.sessionId)
        return ProjectOrdering(now: environment.now(), calendar: environment.calendar, liveSessions: Set(live),
                               busyProjects: Set(commandRuns.filter(\.running).map(\.projectId)))
    }

    /// Todos los proyectos en el orden en que se ven, con «Terminales» al final.
    public var visibleProjects: [ProjectOrdering.Item] { projectOrdering.arrange(projects) }

    /// Fija un proyecto arriba (queda último de los fijados) o lo desfija (pasa a ser el primero de su grupo).
    public func setPinned(_ pinned: Bool, project id: UUID) {
        guard let project = project(id), !project.isScratch, project.pinned != pinned else { return }
        projects = projectOrdering.pinning(projects, id: id, pinned: pinned)
        scheduleSave()
    }

    /// Arrastrar dentro de un grupo: los índices son de la lista del grupo, como los da `onMove`.
    public func moveProjects(in group: ProjectOrdering.Group, from source: IndexSet, to destination: Int) {
        guard group != .scratch else { return }
        projects = projectOrdering.moving(projects, in: group, fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    /// Arrastrar un proyecto sobre otro en el riel: toma su lugar si son del mismo grupo.
    /// Devuelve si se movió.
    @discardableResult
    public func moveProject(_ id: UUID, onto target: UUID) -> Bool {
        guard let moved = projectOrdering.moving(projects, dragging: id, onto: target) else { return false }
        projects = moved
        scheduleSave()
        return true
    }

    /// Cambió el día (pasó la medianoche, o la Mac se despertó al otro día): se recalcula el orden.
    func dayChanged() {
        dayStamp += 1
    }

    /// Escucha el cambio de día del sistema: sin timers, macOS avisa a la medianoche y al despertar.
    func observeDayChanges() {
        guard dayObserver == nil else { return }
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        }
    }
}
