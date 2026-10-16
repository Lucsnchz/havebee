import AppKit
import HiveCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var dropTargeted = false

    var body: some View {
        // El mismo orden que el riel y que ⌃⌘1…⌃⌘9: fijados, activos de hoy, apagados y «Terminales».
        // Cada grupo se reordena arrastrando dentro de él (fijar es con el menú).
        let items = store.visibleProjects
        let pinned = items.filter { $0.group == .pinned }
        List(selection: Binding(get: { store.selection }, set: { store.select($0) })) {
            projectRows(pinned, group: .pinned)
            if !pinned.isEmpty && items.contains(where: { $0.group == .active || $0.group == .idle }) {
                PinnedDivider()
            }
            projectRows(items.filter { $0.group == .active }, group: .active)
            projectRows(items.filter { $0.group == .idle }, group: .idle)

            if let scratchItem = items.last(where: { $0.group == .scratch }), let branch = scratchItem.project.branches.first {
                let scratch = scratchItem.project
                Section {
                    DisclosureGroup(isExpanded: expansion(scratch.id)) {
                        ForEach(branch.activeSessions) { session in
                            SessionRow(project: scratch, branch: branch, session: session)
                                .tag(SidebarItem.session(session.id))
                                .contextMenu { SessionMenu(project: scratch, branch: branch, session: session) }
                        }
                        .onMove { store.moveSessions(in: branch.id, from: $0, to: $1) }
                    } label: {
                        ProjectRow(project: scratch, isActive: scratchItem.isActive)
                            .tag(SidebarItem.project(scratch.id))
                            .contextMenu { ScratchMenu(project: scratch, branch: branch) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // ⏎ en una sesión: pasar a escribirle (las flechas solo la muestran, sin sacarle el foco al sidebar).
        .onKeyPress(.return) {
            guard case .session(let id)? = store.selection else { return .ignored }
            store.requestTerminalFocus(id)
            return .handled
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HomeRow()
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // Los límites de las cuentas de Claude y Codex (nada mientras no haya datos).
                UsageSummary(insets: EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                HStack {
                    Button {
                        store.addProjectInteractive()
                    } label: {
                        Label("Agregar proyecto", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Agregar un repositorio (también podés arrastrar carpetas acá)")
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Soltar carpetas en el sidebar las agrega como proyectos.
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(Self.isFolder)
            guard !folders.isEmpty else { return false }
            Task { for folder in folders { await store.addProject(at: folder.path) } }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private func projectRows(_ items: [ProjectOrdering.Item], group: ProjectOrdering.Group) -> some View {
        ForEach(items) { item in
            ProjectNode(project: item.project, isActive: item.isActive)
        }
        .onMove { store.moveProjects(in: group, from: $0, to: $1) }
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(get: { store.isExpanded(id) }, set: { store.setExpanded(id, $0) })
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// MARK: - Filas

/// Un proyecto del árbol con sus ramas y sesiones.
private struct ProjectNode: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let isActive: Bool

    var body: some View {
        DisclosureGroup(isExpanded: expansion(project.id)) {
            ForEach(project.branches) { branch in
                DisclosureGroup(isExpanded: expansion(branch.id)) {
                    ForEach(branch.activeSessions) { session in
                        SessionRow(project: project, branch: branch, session: session)
                            .tag(SidebarItem.session(session.id))
                            .contextMenu { SessionMenu(project: project, branch: branch, session: session) }
                    }
                    .onMove { store.moveSessions(in: branch.id, from: $0, to: $1) }
                } label: {
                    BranchRow(project: project, branch: branch)
                        .tag(SidebarItem.branch(branch.id))
                        .contextMenu { BranchMenu(project: project, branch: branch) }
                }
            }
            .onMove { store.moveBranches(in: project.id, from: $0, to: $1) }
        } label: {
            ProjectRow(project: project, isActive: isActive)
                .tag(SidebarItem.project(project.id))
                .contextMenu { ProjectMenu(project: project) }
        }
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(get: { store.isExpanded(id) }, set: { store.setExpanded(id, $0) })
    }
}

/// Divisor fino entre los proyectos fijados y el resto (no se elige ni se arrastra).
private struct PinnedDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 4)
            .selectionDisabled()
            .accessibilityHidden(true)
    }
}

/// Fila fija de arriba: vuelve al Inicio y dice cuántas sesiones te esperan.
private struct HomeRow: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let activity = store.activity(of: store.projects.flatMap(\.activeSessions))
        let selected = store.selection == nil
        Button {
            store.select(nil)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Inicio")
                    .font(HiveFont.body.weight(.semibold))
                Spacer(minLength: 4)
                ActivityBadge(activity: activity)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.primary.opacity(selected ? 0.1 : (hovering ? 0.05 : 0)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Las sesiones que te esperan, en todos los proyectos")
        .accessibilityLabel(ActivityBadge.homeAccessibilityText(activity))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ProjectRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    /// Tiene algo prendido o se usó hoy. Si no, se ve atenuado, como en el riel.
    var isActive = true
    @State private var hovering = false

    var body: some View {
        let activity = store.activity(of: project)
        // Con el proyecto abierto, cada sesión ya muestra su estado: el globito sería repetirlo.
        let showsBadge = !store.isExpanded(project.id) && activity.waitingForYou > 0
        // Como en el riel: no se atenúa si estás adentro (el proyecto, una rama o una sesión suya).
        let dimmed = DimmedProject.dims(isActive: isActive, isCurrent: store.currentProjectId == project.id, hovering: hovering)
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ProjectTile(project: project, size: 20, activity: activity)
                    .padding(2)
                Text(project.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .dimmedProject(dimmed)
            Spacer(minLength: 4)
            if hovering && !project.isScratch {
                Button {
                    store.newBranchTarget = NewBranchTarget(id: project.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Nueva rama…")
                .accessibilityLabel("Nueva rama en \(project.name)")
            } else if showsBadge {
                ActivityBadge(activity: activity)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(project.path.tildePath)
        .accessibilityElement(children: .combine)
        // Lo mismo que dice el riel, con «Proyecto» delante: en el árbol también hay ramas y sesiones.
        .accessibilityLabel(ActivityBadge.projectAccessibilityLabel("Proyecto \(project.name)", pinned: project.pinned,
                                                                    activity: activity, isActive: isActive))
        .accessibilityValue(ActivityBadge.projectAccessibilityValue(activity))
    }
}

private struct BranchRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    @State private var hovering = false

    var body: some View {
        let active = store.isActive(branch, in: project)
        let status = store.gitStatus(for: branch, in: project)
        let tint = (branch.color ?? project.tint).color
        // Lo sabe la revisión de git (en segundo plano): mirar el disco acá sería hacerlo en cada dibujo.
        let missing = store.isMissing(branch)
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(tint)
                .opacity(active ? 1 : 0.45)
            Text(branch.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(active ? .primary : .secondary)
            if branch.mode == .worktree {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Worktree")
            }
            Spacer(minLength: 4)
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.attention)
            }
            if hovering {
                Menu {
                    NewSessionItems(branchId: branch.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Nueva sesión en \(branch.name)")
                .accessibilityLabel("Nueva sesión en \(branch.name)")
            } else {
                if let status {
                    GitCounters(status: status)
                }
                // Con la rama abierta, cada sesión ya muestra su estado.
                if !store.isExpanded(branch.id) {
                    AggregateIndicator(sessions: branch.activeSessions)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(helpText(active: active, missing: missing))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(active: active, missing: missing, status: status))
    }

    private func helpText(active: Bool, missing: Bool) -> String {
        if missing {
            return "La carpeta del worktree ya no existe: \(branch.worktreePath?.tildePath ?? ""). La rama se va sola de Hive cuando termine lo que corre ahí."
        }
        if branch.mode == .worktree { return "Worktree en \(branch.worktreePath?.tildePath ?? "")" }
        if active { return "Activa en la carpeta principal" }
        let head = store.mainHeads[project.id] ?? ""
        return "Inactiva: la carpeta principal está en «\(head)»"
    }

    private func accessibilityText(active: Bool, missing: Bool, status: GitStatus?) -> String {
        var parts = ["Rama \(branch.name)"]
        if branch.mode == .worktree { parts.append("worktree") } else if !active { parts.append("inactiva") }
        if missing { parts.append("la carpeta ya no existe") }
        if let status, !status.isClean { parts.append(GitCounters.description(status)) }
        if let text = store.activity(of: branch.activeSessions).ring.accessibilityText { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}

struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    let session: Session

    var body: some View {
        let rt = store.runtimes[session.id]
        HStack(spacing: 7) {
            AgentLogo(kind: session.kind, size: 15)
            Text(session.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let rt {
                StatusIndicator(status: rt.status, unseen: rt.unseen, kind: session.kind)
            }
        }
        // Al pasar el mouse, lo que pide el agente si espera tu permiso.
        .help(Self.helpText(notice: rt?.notice) ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(rt))
    }

    private func accessibilityText(_ rt: SessionRuntime?) -> String {
        var text = "\(session.name), \(session.kind.label)"
        if let rt, rt.status != .dormant {
            text += ", " + StatusIndicator.accessibilityText(status: rt.status, unseen: rt.unseen, kind: session.kind)
        }
        if let notice = Self.helpText(notice: rt?.notice) { text += ". " + notice }
        return text
    }

    /// «Necesita permiso: Pide permiso para editar app.php», o nil si no pide nada.
    static func helpText(notice: String?) -> String? {
        guard let notice = notice?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty else { return nil }
        return "Necesita permiso: \(notice)"
    }
}

// MARK: - Menús contextuales

struct ProjectMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        Button("Nueva rama…") { store.newBranchTarget = NewBranchTarget(id: project.id) }
        Divider()
        // Fijado: arriba de todo en el riel y en el árbol, aunque hoy no lo uses.
        Button(project.pinned ? "Dejar de fijar" : "Fijar arriba") { store.setPinned(!project.pinned, project: project.id) }
        MoveItems(item: .project(project.id))
        Divider()
        Button("Personalizar…") { store.customizeTarget = CustomizeTarget(id: project.id) }
        TintColorMenu { color in if let color { store.setColor(color, project: project.id) } }
        Divider()
        OpenInItems(path: project.path)
        Divider()
        Button("Renombrar…") { store.beginRename(.project(project.id)) }
        Button("Quitar proyecto…") { store.requestRemoval(.project(project.id)) }
    }
}

struct BranchMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch

    var body: some View {
        NewSessionItems(branchId: branch.id)
        if !store.isActive(branch, in: project) {
            Divider()
            Button("Hacer checkout en la carpeta principal") { store.requestCheckout(branchId: branch.id) }
        }
        Divider()
        TintColorMenu(defaultTitle: "Color del proyecto") { store.setColor($0, branch: branch.id) }
        MoveItems(item: .branch(branch.id))
        Divider()
        OpenInItems(path: project.directory(for: branch))
        Divider()
        Button("Quitar rama…") { store.requestRemoval(.branch(branch.id)) }
    }
}

struct SessionMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    let session: Session

    var body: some View {
        let rt = store.runtimes[session.id]
        Button("Renombrar…") { store.beginRename(.session(session.id)) }
        if rt?.isRunning == true {
            Button("Reiniciar") { store.relaunch(session.id) }
            Button("Detener") { store.stop(session.id) }
        } else if case .exited? = rt?.status {
            Button("Reanudar") { store.relaunch(session.id) }
        }
        MoveItems(item: .session(session.id))
        Divider()
        Button("Archivar") { store.requestArchive(session.id) }
        Button("Eliminar sesión…") { store.requestRemoval(.session(session.id)) }
    }
}

/// Menú del proyecto «Terminales».
struct ScratchMenu: View {
    let project: Project
    let branch: Branch

    var body: some View {
        NewSessionItems(branchId: branch.id)
        Divider()
        OpenInItems(path: project.path)
    }
}

/// «Subir» / «Bajar»: alternativa a arrastrar en el sidebar (un proyecto, dentro de su grupo).
struct MoveItems: View {
    @Environment(AppStore.self) private var store
    let item: SidebarItem

    var body: some View {
        let position = store.position(of: item)
        Button("Subir") { store.move(item, by: -1) }
            .disabled((position?.index ?? 0) == 0)
        Button("Bajar") { store.move(item, by: 1) }
            .disabled(position.map { $0.index >= $0.count - 1 } ?? true)
    }
}

struct NewSessionItems: View {
    @Environment(AppStore.self) private var store
    let branchId: UUID

    var body: some View {
        let availability = AgentAvailability.shared(for: store)
        // Los ítems de un agente sin instalar no se pueden tocar para volver a revisar: se revisa
        // al armar el menú (como mucho cada 10 s; el resultado llega al toque).
        let _ = availability.refreshIfStale()
        ForEach(SessionKind.allCases) { kind in
            let installed = availability.isInstalled(kind)
            Button {
                store.requestNewSession(branchId: branchId, kind: kind)
            } label: {
                Label {
                    Text(installed ? "Nueva sesión de \(kind.label)" : "Nueva sesión de \(kind.label) (no instalado)")
                } icon: {
                    Image(nsImage: AgentLogo.menuImage(kind))
                }
            }
            .disabled(!installed)
        }
    }
}

/// Submenú «Color» con la paleta de proyectos (y, si se pasa, una opción para volver al color por defecto).
struct TintColorMenu: View {
    var title = "Color"
    /// Título de la opción que vuelve al color por defecto (nil para no ofrecerla).
    var defaultTitle: String?
    let onSelect: (TintColor?) -> Void

    var body: some View {
        Menu(title) {
            if let defaultTitle {
                Button(defaultTitle) { onSelect(nil) }
                Divider()
            }
            ForEach(TintColor.allCases) { color in
                Button {
                    onSelect(color)
                } label: {
                    Label { Text(color.label) } icon: { Image(nsImage: color.swatch) }
                }
            }
        }
    }
}

struct OpenInItems: View {
    let path: String

    var body: some View {
        Button("Mostrar en Finder") { ExternalApps.revealInFinder(path) }
        ForEach(ExternalApps.editors + ExternalApps.terminals) { app in
            Button {
                ExternalApps.open(path, with: app)
            } label: {
                Label { Text("Abrir en \(app.name)") } icon: { Image(nsImage: ExternalApps.icon(app)) }
            }
        }
        Button("Copiar ruta") { ExternalApps.copyToPasteboard(path) }
    }
}
