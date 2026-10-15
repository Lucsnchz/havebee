import HiveCore
import SwiftUI

/// Alto mínimo de las tarjetas de rama (y de «Nueva rama», para que la fila quede pareja).
private let branchCardHeight: CGFloat = 76

/// Resumen de un proyecto: sus ramas (lo de todos los días), los comandos y los MCP.
struct ProjectDetailView: View {
    @Environment(AppStore.self) private var store
    let projectId: UUID

    var body: some View {
        if let project = store.project(projectId) {
            let head = store.mainHeads[project.id] ?? ""
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ProjectHeader(project: project, head: head)

                    if !head.isEmpty && !project.branches.contains(where: { $0.mode == .main && $0.name == head }) {
                        Callout(icon: "info.circle.fill", color: .blue,
                                title: "«\(head)» no está en Hive",
                                text: "Es la rama que tiene ahora la carpeta principal.",
                                action: ("Agregar", {
                                    Task {
                                        _ = await store.createBranch(NewBranchRequest(projectId: project.id, name: head, isNew: false,
                                                                                      base: "", mode: .main, firstSession: nil))
                                    }
                                }))
                    }

                    DetailSection("Ramas") {
                        LazyVGrid(columns: HiveCard.gridColumns, alignment: .leading, spacing: 12) {
                            ForEach(project.branches) { branch in
                                BranchCard(project: project, branch: branch)
                            }
                            NewBranchCard { store.newBranchTarget = NewBranchTarget(id: project.id) }
                        }
                    }

                    DetailSection("Comandos", trailing: {
                        SectionAddButton(help: "Agregar un comando") {
                            store.commandEditor = CommandEditorTarget(projectId: project.id, commandId: nil)
                        }
                    }) {
                        // El «Agregar» va en el título de la sección: no repetirlo abajo.
                        CommandsSection(project: project, showsAddButton: false)
                    }

                    DetailSection("MCP", trailing: {
                        SectionAddButton(help: "Agregar un servidor MCP") {
                            store.mcpEditor = MCPEditorTarget(projectId: project.id, serverName: nil)
                        }
                    }) {
                        MCPSection(project: project, showsAddButton: false)
                    }
                }
                .padding(28)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(project.name)
            .navigationSubtitle(head.isEmpty ? "HEAD desacoplado" : "en \(head)")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        store.newBranchTarget = NewBranchTarget(id: project.id)
                    } label: {
                        Label("Nueva rama", systemImage: "plus")
                    }
                    .help("Nueva rama o worktree")
                    Button {
                        store.customizeTarget = CustomizeTarget(id: project.id)
                    } label: {
                        Label("Personalizar", systemImage: "paintpalette")
                    }
                    .help("Color e ícono del proyecto")
                    OpenInMenu(path: project.path)
                }
            }
        }
    }
}

private struct ProjectHeader: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let head: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Button {
                store.customizeTarget = CustomizeTarget(id: project.id)
            } label: {
                ProjectTile(project: project, size: 56, activity: store.activity(of: project))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Personalizar color e ícono")
            .accessibilityLabel("Personalizar color e ícono de \(project.name)")
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(HiveFont.title)
                    .textSelection(.enabled)
                Text("Carpeta principal en «\(head.isEmpty ? "HEAD desacoplado" : head)»")
                    .font(HiveFont.secondary)
                    .foregroundStyle(.secondary)
                CopyablePath(path: project.path)
            }
        }
    }
}

/// «+ Agregar» chico, para el encabezado de una sección.
struct SectionAddButton: View {
    var title = "Agregar"
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(HiveFont.secondary.weight(.medium))
        .help(help)
    }
}

struct BranchCard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch

    var body: some View {
        let active = store.isActive(branch, in: project)
        let status = store.gitStatus(for: branch, in: project)
        let tint = (branch.color ?? project.tint).color
        Button {
            store.select(.branch(branch.id))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(tint)
                        .opacity(active ? 1 : 0.45)
                    Text(branch.name)
                        .font(HiveFont.heading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(active ? .primary : .secondary)
                    Spacer(minLength: 6)
                    Text(modeLabel(active: active))
                        .font(HiveFont.meta.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let status {
                        if status.isClean {
                            Text("Sin cambios").font(HiveFont.meta).foregroundStyle(.tertiary)
                        } else {
                            GitCounters(status: status)
                        }
                    } else {
                        Text(active ? "—" : "Sin checkout").font(HiveFont.meta).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    SessionFaces(branch: branch)
                }
                .frame(height: 22)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: branchCardHeight, alignment: .topLeading)
            .hiveCard(interactive: true)
        }
        .buttonStyle(.plain)
        .contextMenu { BranchMenu(project: project, branch: branch) }
        .accessibilityLabel(accessibilityText(active: active, status: status))
        .accessibilityHint("Abre la rama")
    }

    private func modeLabel(active: Bool) -> String {
        branch.mode == .worktree ? "Worktree" : (active ? "Principal" : "Inactiva")
    }

    private func accessibilityText(active: Bool, status: GitStatus?) -> String {
        var parts = ["Rama \(branch.name)", modeLabel(active: active)]
        if let status { parts.append(status.isClean ? "sin cambios" : GitCounters.description(status)) }
        let sessions = branch.activeSessions.count
        if sessions > 0 { parts.append(sessions == 1 ? "1 sesión" : "\(sessions) sesiones") }
        let ring = store.activity(of: branch.activeSessions).ring
        if let text = ring.accessibilityText { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}

/// Los logos de las sesiones de una rama, con un puntito de color si algo se destaca.
private struct SessionFaces: View {
    @Environment(AppStore.self) private var store
    let branch: Branch

    var body: some View {
        HStack(spacing: -3) {
            ForEach(branch.activeSessions.prefix(6)) { session in
                AgentLogo(kind: session.kind, size: 16)
                    .padding(3)
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        if let rt = store.runtimes[session.id],
                           let color = Activity.Ring.of(status: rt.status, unseen: rt.unseen).color {
                            Circle()
                                .fill(color)
                                .frame(width: 7, height: 7)
                        }
                    }
            }
            if branch.activeSessions.count > 6 {
                Text("+\(branch.activeSessions.count - 6)")
                    .font(HiveFont.meta.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
        .accessibilityHidden(true)
    }
}

struct NewBranchCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Nueva rama", systemImage: "plus")
                .font(HiveFont.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: branchCardHeight)
                .hiveCard(interactive: true, dashed: true)
        }
        .buttonStyle(.plain)
        .help("Nueva rama o worktree")
    }
}
