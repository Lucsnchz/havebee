import HiveCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List(selection: Binding(get: { store.selection }, set: { store.select($0) })) {
            ForEach(store.repoProjects) { project in
                DisclosureGroup(isExpanded: expansion(project.id)) {
                    ForEach(project.branches) { branch in
                        DisclosureGroup(isExpanded: expansion(branch.id)) {
                            ForEach(branch.activeSessions) { session in
                                SessionRow(session: session)
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
                    ProjectRow(project: project)
                        .tag(SidebarItem.project(project.id))
                        .contextMenu { ProjectMenu(project: project) }
                }
            }
            .onMove { store.moveProjects(from: $0, to: $1) }

            if let scratch = store.scratchProject, let branch = scratch.branches.first {
                Section {
                    DisclosureGroup(isExpanded: expansion(scratch.id)) {
                        ForEach(branch.activeSessions) { session in
                            SessionRow(session: session)
                                .tag(SidebarItem.session(session.id))
                                .contextMenu { SessionMenu(project: scratch, branch: branch, session: session) }
                        }
                        .onMove { store.moveSessions(in: branch.id, from: $0, to: $1) }
                    } label: {
                        ProjectRow(project: scratch)
                            .tag(SidebarItem.project(scratch.id))
                            .contextMenu { ScratchMenu(project: scratch, branch: branch) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    store.addProjectInteractive()
                } label: {
                    Label("Agregar proyecto", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(get: { store.isExpanded(id) }, set: { store.setExpanded(id, $0) })
    }
}

// MARK: - Filas

private struct ProjectRow: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let activity = store.activity(of: project)
        HStack(spacing: 8) {
            ProjectTile(project: project, size: 20, activity: activity)
                .padding(2)
            Text(project.name)
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 4)
            if activity.waitingForYou > 0 {
                Text("\(activity.waitingForYou)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(activity.attention > 0 ? Color.orange : Color.green, in: Capsule())
                    .help(activity.waitingForYou == 1 ? "Una sesión te espera" : "\(activity.waitingForYou) sesiones te esperan")
            }
        }
        .padding(.vertical, 1)
        .help(project.path)
    }
}

private struct BranchRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch

    var body: some View {
        let active = store.isActive(branch, in: project)
        let status = store.gitStatus(for: branch, in: project)
        let tint = (branch.color ?? project.tint).color
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(tint)
                .opacity(active ? 1 : 0.45)
            Text(branch.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(active ? .primary : .secondary)
            if branch.mode == .worktree {
                Text("WT")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 4)
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            if let status {
                GitCounters(status: status)
            }
            AggregateIndicator(sessions: branch.activeSessions)
        }
        .help(helpText(active: active))
    }

    private var missing: Bool {
        guard branch.mode == .worktree, let path = branch.worktreePath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    private func helpText(active: Bool) -> String {
        if missing { return "La carpeta del worktree ya no existe: \(branch.worktreePath ?? "")" }
        if branch.mode == .worktree { return "Worktree en \(branch.worktreePath ?? "")" }
        if active { return "Activa en la carpeta principal" }
        let head = store.mainHeads[project.id] ?? ""
        return "Inactiva: la carpeta principal está en «\(head)»"
    }
}

private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        HStack(spacing: 7) {
            AgentLogo(kind: session.kind, size: 15)
            Text(session.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let rt = store.runtimes[session.id] {
                StatusIndicator(status: rt.status, unseen: rt.unseen, kind: session.kind)
            }
        }
    }
}

struct GitCounters: View {
    let status: GitStatus

    var body: some View {
        HStack(spacing: 4) {
            if !status.changes.isEmpty {
                Text("\(status.changes.count)")
                    .foregroundStyle(Color(red: 0.89, green: 0.75, blue: 0.55))
                    .help("\(status.changes.count) archivos con cambios")
            }
            if status.ahead > 0 { Text("↑\(status.ahead)").help("\(status.ahead) commits sin pushear") }
            if status.behind > 0 { Text("↓\(status.behind)").help("\(status.behind) commits sin traer") }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

// MARK: - Menús contextuales

struct ProjectMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        Button("Nueva rama…") { store.newBranchTarget = NewBranchTarget(id: project.id) }
        Divider()
        Button("Personalizar…") { store.customizeTarget = CustomizeTarget(id: project.id) }
        Menu("Color") {
            ForEach(TintColor.allCases) { color in
                Button {
                    store.setColor(color, project: project.id)
                } label: {
                    Label { Text(color.label) } icon: { Image(nsImage: color.swatch) }
                }
            }
        }
        MoveItems(item: .project(project.id))
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
        Menu("Color") {
            Button("Color del proyecto") { store.setColor(nil, branch: branch.id) }
            Divider()
            ForEach(TintColor.allCases) { color in
                Button {
                    store.setColor(color, branch: branch.id)
                } label: {
                    Label { Text(color.label) } icon: { Image(nsImage: color.swatch) }
                }
            }
        }
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

/// "Subir" / "Bajar": alternativa a arrastrar en el sidebar.
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
        ForEach(SessionKind.allCases) { kind in
            Button {
                store.requestNewSession(branchId: branchId, kind: kind)
            } label: {
                Label { Text("Nueva sesión de \(kind.label)") } icon: { Image(nsImage: AgentLogo.menuImage(kind)) }
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
