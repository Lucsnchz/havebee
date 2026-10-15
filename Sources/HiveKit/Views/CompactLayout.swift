import AppKit
import HiveCore
import SwiftUI

/// Vista compacta: barra angosta con los proyectos y las sesiones del proyecto como pestañas.
struct CompactLayout: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            ProjectRail()
            Divider()
            if let id = store.currentProjectId, let project = store.project(id) {
                VStack(spacing: 0) {
                    ProjectTabBar(project: project)
                    Divider()
                    DetailView()
                }
            } else {
                EmptyDetailView()
            }
        }
    }
}

// MARK: - Barra de proyectos

private struct ProjectRail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    ForEach(store.repoProjects) { project in
                        RailItem(project: project)
                    }
                }
                .padding(.vertical, 14)
            }
            Divider().padding(.horizontal, 16)
            if let scratch = store.scratchProject {
                RailItem(project: scratch)
                    .padding(.top, 10)
            }
            Button {
                store.addProjectInteractive()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Agregar proyecto")
            .padding(.vertical, 12)
        }
        .frame(width: 72)
        .background(VisualEffectBackground(material: .sidebar))
    }
}

struct RailItem: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var hovering = false

    var body: some View {
        let selected = store.currentProjectId == project.id
        ZStack(alignment: .leading) {
            // Indicador del proyecto activo, como en Discord.
            Capsule()
                .fill(Color.primary)
                .frame(width: 4, height: selected ? 30 : (hovering ? 12 : 0))
                .offset(x: -2)
                .animation(.easeOut(duration: 0.15), value: selected)
                .animation(.easeOut(duration: 0.15), value: hovering)
            ProjectTile(project: project, size: 40, activity: store.activity(of: project), showsBadge: true)
                .opacity(selected || hovering ? 1 : 0.85)
                .scaleEffect(hovering && !selected ? 1.04 : 1)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 72, height: 44)
        .contentShape(Rectangle())
        .onTapGesture { store.openProject(project.id) }
        .onHover { hovering = $0 }
        .help(project.name)
        .contextMenu {
            if project.isScratch, let branch = project.branches.first {
                ScratchMenu(project: project, branch: branch)
            } else {
                ProjectMenu(project: project)
            }
        }
    }
}

// MARK: - Pestañas

private struct ProjectTabBar: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let sessions = project.branches.flatMap { branch in branch.activeSessions.map { (branch, $0) } }
        let showBranch = Set(sessions.map(\.0.id)).count > 1
        HStack(spacing: 0) {
            OverviewTab(project: project)
            Divider().frame(height: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessions, id: \.1.id) { branch, session in
                        SessionTab(project: project, branch: branch, session: session, showBranch: showBranch)
                    }
                }
                .padding(.horizontal, 6)
            }
            NewSessionButton(project: project)
                .padding(.horizontal, 6)
        }
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct OverviewTab: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var hovering = false

    var body: some View {
        let selected: Bool = {
            switch store.selection {
            case .project(let id)?: id == project.id
            case .branch(let id)?: project.branches.contains { $0.id == id }
            default: false
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
            Text("Resumen")
        }
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(selected ? Color.primary.opacity(0.08) : (hovering ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { store.select(.project(project.id)) }
        .onHover { hovering = $0 }
    }
}

struct SessionTab: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    let session: Session
    let showBranch: Bool
    @State private var hovering = false

    var body: some View {
        let selected = store.selection == .session(session.id)
        let rt = store.runtimes[session.id]
        HStack(spacing: 6) {
            AgentLogo(kind: session.kind, size: 14)
            Text(session.name)
                .lineLimit(1)
                .fixedSize()
            if showBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                    Text(Self.shortened(branch.name))
                        .lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle((branch.color ?? project.tint).color)
                .fixedSize()
            }
            ZStack {
                if let rt, !hovering {
                    StatusIndicator(status: rt.status, unseen: rt.unseen, kind: session.kind)
                }
                if hovering {
                    Button {
                        store.requestArchive(session.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Color.primary.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Cerrar pestaña (archiva la sesión; la podés restaurar desde la rama)")
                }
            }
            .frame(width: 16)
        }
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(minWidth: 120, minHeight: 30)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.09) : (hovering ? Color.primary.opacity(0.05) : .clear))
        }
        .overlay(alignment: .bottom) {
            if selected {
                Capsule().fill(project.tint.color).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.select(.session(session.id)) }
        .onHover { hovering = $0 }
        .help("\(session.name) · \(branch.name)")
        .contextMenu { SessionMenu(project: project, branch: branch, session: session) }
    }

    /// Las ramas largas se acortan por el medio para que la pestaña no crezca de más.
    static func shortened(_ name: String, max: Int = 18) -> String {
        guard name.count > max else { return name }
        let keep = (max - 1) / 2
        return String(name.prefix(keep)) + "…" + String(name.suffix(max - 1 - keep))
    }
}

/// "+" de la barra de pestañas: nueva sesión en la rama actual u otra.
private struct NewSessionButton: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let current = currentBranch
        Menu {
            if let current {
                Section(project.isScratch ? "En tu carpeta personal" : "En \(current.name)") {
                    NewSessionItems(branchId: current.id)
                }
            }
            let others = project.branches.filter { $0.id != current?.id }
            if !others.isEmpty && !project.isScratch {
                Menu("En otra rama") {
                    ForEach(others) { branch in
                        Menu(branch.name) { NewSessionItems(branchId: branch.id) }
                    }
                }
            }
            if !project.isScratch {
                Divider()
                Button("Nueva rama…") { store.newBranchTarget = NewBranchTarget(id: project.id) }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Nueva sesión")
    }

    /// La rama de la pestaña abierta; si no hay, la de la carpeta principal o la primera.
    private var currentBranch: Branch? {
        switch store.selection {
        case .session(let id)?: if let ctx = store.sessionContext(id) { return ctx.branch }
        case .branch(let id)?: if let ctx = store.branchContext(id) { return ctx.branch }
        default: break
        }
        let head = store.mainHeads[project.id]
        return project.branches.first { $0.mode == .main && $0.name == head } ?? project.branches.first
    }
}

/// Fondo translúcido nativo (el mismo material que la barra lateral de macOS).
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
