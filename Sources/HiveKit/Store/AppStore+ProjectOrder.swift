import AppKit
import HiveCore

/// Un proyecto en el menú Ir: lo único que el menú necesita saber.
public struct MenuProject: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
}

/// Lo que decidís vos del orden de los proyectos: el orden a mano y cuáles están fijados.
struct ManualProjectOrder: Equatable {
    let ids: [UUID]
    let pinned: Set<UUID>

    init(_ projects: [Project]) {
        ids = projects.map(\.id)
        pinned = Set(projects.filter(\.pinned).map(\.id))
    }
}

/// El orden de los proyectos que comparten el riel, el árbol y ⌃⌘1…⌃⌘9 (lo decide
/// `ProjectOrdering`): fijados, activos de hoy, apagados y «Terminales».
extension AppStore {
    /// Las reglas del orden con lo que está pasando ahora: qué está prendido y qué día es.
    var projectOrdering: ProjectOrdering {
        if let heldOrdering { return heldOrdering }
        // Se lee para que las vistas se vuelvan a dibujar cuando cambia el día.
        _ = dayStamp
        // Prendida: con algo que mostrarte (un aro), aunque el proceso ya haya terminado, así un
        // proyecto apagado nunca tiene aro; o una Terminal con un proceso en primer plano (un
        // `npm run dev`). Un agente abierto y quieto no alcanza: mirar una sesión la lanza, y el
        // proyecto que abrís saltaría de grupo (y de lugar en el riel y en ⌃⌘N) con el clic.
        let live = runtimes.values.filter { rt in
            rt.unseen || rt.status == .attention || rt.status == .working
                || (!rt.kind.isAgent && rt.terminal?.foregroundJob != nil)
        }.map(\.sessionId)
        return ProjectOrdering(now: environment.now(), calendar: environment.calendar, liveSessions: Set(live),
                               busyProjects: Set(commandRuns.filter(\.running).map(\.projectId)))
    }

    /// Todos los proyectos en el orden en que se ven, con «Terminales» al final.
    public var visibleProjects: [ProjectOrdering.Item] { projectOrdering.arrange(projects) }

    /// El puntero entró al riel o al árbol (`true`) o salió. Mientras está ahí, el orden no cambia
    /// solo: un proyecto que empieza a trabajar o que te espera no se mueve debajo del clic. Lo que
    /// cambiás vos (fijar, arrastrar, agregar) se aplica igual. Al salir, se acomoda.
    public func holdProjectOrder(_ hold: Bool) {
        if hold, heldOrdering == nil {
            heldOrdering = projectOrdering
        } else if !hold, heldOrdering != nil {
            heldOrdering = nil
        }
    }

    /// El orden de ⌃⌘1…⌃⌘9 y ⌥⌘↓ / ⌥⌘↑: el que se ve. Si recién cambió solo, durante un segundo
    /// sigue el de antes, que es el que estabas mirando cuando apretaste.
    public var shortcutProjects: [Project] {
        let visible = visibleProjects.map(\.project)
        guard let previous = previousOrder, environment.now() < previous.until else { return visible }
        let byId = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        return previous.ids.compactMap { byId[$0] }
    }

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

    /// Si el proyecto arrastrado en el riel se puede soltar sobre `target` (del mismo grupo). Si no,
    /// el puntero lo muestra como prohibido: fijar es con el menú.
    public func canMoveProject(_ id: UUID, onto target: UUID) -> Bool {
        projectOrdering.canDrag(id, onto: target, in: projects)
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

    /// Copia el orden a `menuProjects` y se queda mirando lo que lo decide. El orden depende del estado
    /// de cada sesión: si el menú Ir lo leyera directo, todo `HiveCommands` se volvería a armar con cada
    /// cambio de estado de cualquier sesión. Así, cuando algo cambia se recalcula en la próxima vuelta
    /// del hilo principal y el menú se entera solo si cambiaron el orden o un nombre.
    func trackMenuProjects() {
        let items = withObservationTracking {
            visibleProjects.map { MenuProject(id: $0.id, name: $0.project.name) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackMenuProjects() }
        }
        let manual = ManualProjectOrder(projects)
        if !menuProjects.isEmpty, items.map(\.id) != menuProjects.map(\.id), manual == lastManualOrder {
            previousOrder = (menuProjects.map(\.id), environment.now().addingTimeInterval(1))
        }
        lastManualOrder = manual
        if items != menuProjects { menuProjects = items }
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
