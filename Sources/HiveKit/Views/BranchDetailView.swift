import HiveCore
import SwiftUI

// MARK: - Rama

struct BranchDetailView: View {
    @Environment(AppStore.self) private var store
    let branchId: UUID

    var body: some View {
        if let ctx = store.branchContext(branchId) {
            let active = store.isActive(ctx.branch, in: ctx.project)
            let dir = ctx.project.directory(for: ctx.branch)
            let status = store.gitStatus(for: ctx.branch, in: ctx.project)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if ctx.project.isScratch {
                        ScratchHeader(directory: dir)
                    } else {
                        BranchHeader(project: ctx.project, branch: ctx.branch, status: status, directory: dir)
                    }

                    if !active {
                        Callout(icon: "pause.circle.fill", color: .orange,
                                title: "Rama inactiva",
                                text: "La carpeta principal está en «\(store.mainHeads[ctx.project.id] ?? "")». Para trabajar acá hay que hacer checkout.",
                                action: ("Hacer checkout", { store.requestCheckout(branchId: branchId) }))
                    }

                    DetailSection("Nueva sesión") {
                        HStack(spacing: 10) {
                            ForEach(SessionKind.allCases) { kind in
                                NewSessionCard(kind: kind) { store.requestNewSession(branchId: branchId, kind: kind) }
                            }
                        }
                    }

                    if !ctx.branch.activeSessions.isEmpty {
                        DetailSection("Sesiones") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                                ForEach(ctx.branch.activeSessions) { session in
                                    SessionCard(project: ctx.project, branch: ctx.branch, session: session)
                                }
                            }
                        }
                    }

                    if !ctx.project.commands.isEmpty && !ctx.project.isScratch {
                        DetailSection("Comandos") {
                            CommandsSection(project: ctx.project, branch: ctx.branch, editable: false)
                        }
                    }

                    if !ctx.project.isScratch {
                    // La lista ya tiene sus propios títulos ("Preparados" / "Cambios").
                    DetailSection("Git") {
                        Group {
                            if let status {
                                ChangesList(status: status, directory: dir)
                                    .padding(.vertical, 4)
                            } else {
                                Text("Sin información de git para esta rama.")
                                    .foregroundStyle(.secondary)
                                    .padding(14)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground()
                    }

                    DetailSection("Últimos commits") {
                        RecentCommits(git: store.git, directory: dir, refreshKey: "\(status?.ahead ?? 0)-\(status?.behind ?? 0)-\(status?.changes.count ?? 0)")
                            .cardBackground()
                    }
                    }

                    if !ctx.branch.archivedSessions.isEmpty {
                        ArchivedSessions(sessions: ctx.branch.archivedSessions)
                    }
                }
                .padding(28)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(ctx.project.isScratch ? ctx.project.name : ctx.branch.name)
            .navigationSubtitle(ctx.project.isScratch ? dir : ctx.project.name)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        NewSessionItems(branchId: branchId)
                    } label: {
                        Label("Nueva sesión", systemImage: "plus")
                    }
                    OpenInMenu(path: dir)
                }
            }
        }
    }
}

private struct ScratchHeader: View {
    let directory: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(TintColor.gray.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Terminales").font(.title2.bold())
                Text("Terminales y agentes sueltos, fuera de cualquier repo. Arrancan en \(directory).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BranchHeader: View {
    let project: Project
    let branch: Branch
    let status: GitStatus?
    let directory: String

    var body: some View {
        let tint = (branch.color ?? project.tint).color
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(branch.name)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                    Chip(text: branch.mode == .worktree ? "Worktree" : "Carpeta principal")
                    if let status {
                        if status.ahead > 0 { Chip(text: "↑ \(status.ahead)", help: "Commits sin pushear") }
                        if status.behind > 0 { Chip(text: "↓ \(status.behind)", help: "Commits sin traer") }
                    }
                }
                HStack(spacing: 6) {
                    Text(directory)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        ExternalApps.copyToPasteboard(directory)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copiar ruta")
                }
            }
        }
    }
}

struct NewSessionCard: View {
    let kind: SessionKind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AgentLogo(kind: kind, size: 26)
                Text(kind.label)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(hovering ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.18 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Nueva sesión de \(kind.label)")
    }
}

/// Tarjeta de una sesión: estado, hace cuánto se usó y lo último que respondió el agente.
struct SessionCard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    let session: Session
    @State private var hovering = false

    var body: some View {
        let rt = store.runtimes[session.id]
        let status = rt?.status ?? .dormant
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentLogo(kind: session.kind, size: 18)
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    StatusIndicator(status: status, unseen: rt?.unseen ?? false, kind: session.kind)
                    Text(status.label(for: session.kind))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor(status, unseen: rt?.unseen ?? false))
                }
            }
            Text(summary(rt))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            if let date = session.lastActivityAt ?? session.lastLaunchedAt {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(borderColor(status: status, unseen: rt?.unseen ?? false)))
        .contentShape(Rectangle())
        .onTapGesture { store.select(.session(session.id)) }
        .onHover { hovering = $0 }
        .contextMenu { SessionMenu(project: project, branch: branch, session: session) }
    }

    /// Naranja si pide permiso, verde si te espera y no la viste.
    private func borderColor(status: SessionStatus, unseen: Bool) -> Color {
        if status == .attention { return Color.orange.opacity(0.7) }
        if unseen { return Color.green.opacity(0.6) }
        return Color.primary.opacity(hovering ? 0.18 : 0.08)
    }

    private func summary(_ rt: SessionRuntime?) -> String {
        if let message = session.lastMessage, !message.isEmpty { return message }
        let title = (rt?.title ?? "").trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
        return session.kind.isAgent ? "Todavía sin respuestas." : "Terminal en \(branch.name)."
    }

    private func statusColor(_ status: SessionStatus, unseen: Bool) -> Color {
        switch status {
        case .working: .honey
        case .attention: .orange
        case .waiting: unseen ? .green : .secondary
        default: .secondary
        }
    }
}

private struct RecentCommits: View {
    let git: GitClient
    let directory: String
    /// Cambia cuando cambia el estado de git, para volver a leer los commits.
    let refreshKey: String
    @State private var commits: [GitCommit] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commits.isEmpty {
                Text(loaded ? "Todavía no hay commits." : "Cargando…")
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                if index > 0 { Divider().padding(.leading, 14) }
                HStack(spacing: 10) {
                    Text(commit.hash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    Text(commit.subject)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(commit.subject)
                    Spacer(minLength: 8)
                    Text(commit.author)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(commit.date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 14)
                .frame(height: 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(directory)|\(refreshKey)") {
            let dir = directory
            let git = self.git
            commits = await Task.detached { git.recentCommits(dir, limit: 8) }.value
            loaded = true
        }
    }
}

// MARK: - Proyecto

struct ProjectDetailView: View {
    @Environment(AppStore.self) private var store
    let projectId: UUID

    var body: some View {
        if let project = store.project(projectId) {
            let head = store.mainHeads[project.id] ?? ""
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center, spacing: 16) {
                        Button {
                            store.customizeTarget = CustomizeTarget(id: project.id)
                        } label: {
                            ProjectTile(project: project, size: 56, activity: store.activity(of: project))
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                        .help("Personalizar color e ícono")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.name).font(.title2.bold())
                            Text(project.path)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text("Carpeta principal en «\(head.isEmpty ? "HEAD desacoplado" : head)»")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

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

                    DetailSection("Comandos") {
                        CommandsSection(project: project)
                    }

                    DetailSection("MCP") {
                        MCPSection(project: project)
                    }

                    DetailSection("Ramas") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(project.branches) { branch in
                                BranchCard(project: project, branch: branch)
                            }
                            NewBranchCard { store.newBranchTarget = NewBranchTarget(id: project.id) }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(project.name)
            .navigationSubtitle(project.path)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        store.newBranchTarget = NewBranchTarget(id: project.id)
                    } label: {
                        Label("Nueva rama", systemImage: "plus")
                    }
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

struct BranchCard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    @State private var hovering = false

    var body: some View {
        let active = store.isActive(branch, in: project)
        let status = store.gitStatus(for: branch, in: project)
        let tint = (branch.color ?? project.tint).color
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(tint)
                    .opacity(active ? 1 : 0.45)
                Text(branch.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(active ? .primary : .secondary)
                Spacer(minLength: 6)
                Text(branch.mode == .worktree ? "Worktree" : (active ? "Principal" : "Inactiva"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let status {
                    if status.changes.isEmpty && status.ahead == 0 && status.behind == 0 {
                        Text("Sin cambios").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        GitCounters(status: status)
                    }
                } else {
                    Text(active ? "—" : "Sin checkout").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                // Las sesiones de la rama, con su estado.
                HStack(spacing: -3) {
                    ForEach(branch.activeSessions.prefix(6)) { session in
                        AgentLogo(kind: session.kind, size: 16)
                            .padding(3)
                            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                            .overlay(alignment: .bottomTrailing) {
                                if let rt = store.runtimes[session.id], rt.unseen || rt.status == .attention || rt.status == .working {
                                    Circle()
                                        .fill(rt.status == .attention ? Color.orange : (rt.unseen ? Color.green : Color.honey))
                                        .frame(width: 7, height: 7)
                                }
                            }
                    }
                    if branch.activeSessions.count > 6 {
                        Text("+\(branch.activeSessions.count - 6)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(hovering ? 0.18 : 0.08)))
        .contentShape(Rectangle())
        .onTapGesture { store.select(.branch(branch.id)) }
        .onHover { hovering = $0 }
        .contextMenu { BranchMenu(project: project, branch: branch) }
    }
}

struct NewBranchCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("Nueva rama", systemImage: "plus")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.primary.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Sesiones archivadas de la rama: se pueden restaurar (con su conversación) o eliminar.
private struct ArchivedSessions: View {
    @Environment(AppStore.self) private var store
    let sessions: [Session]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("ARCHIVADAS (\(sessions.count))")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().padding(.leading, 40) }
                        HStack(spacing: 10) {
                            AgentLogo(kind: session.kind, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name).font(.system(size: 13, weight: .medium))
                                Text(session.lastMessage ?? "Sin respuestas guardadas.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let date = session.archivedAt {
                                Text("archivada \(date.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Button("Restaurar") { store.unarchive(session.id) }
                            Button {
                                store.requestRemoval(.session(session.id))
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Eliminar")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .cardBackground()
            }
        }
    }
}

// MARK: - Piezas comunes

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct Callout: View {
    let icon: String
    let color: Color
    let title: String
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action.0, action: action.1)
            }
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension View {
    func cardBackground() -> some View {
        background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
