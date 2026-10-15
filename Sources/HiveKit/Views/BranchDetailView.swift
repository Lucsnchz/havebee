import AppKit
import HiveCore
import SwiftUI

// MARK: - Rama

/// Una rama: sus sesiones primero (lo de todos los días), después comandos, cambios y commits.
struct BranchDetailView: View {
    @Environment(AppStore.self) private var store
    let branchId: UUID

    var body: some View {
        if let ctx = store.branchContext(branchId) {
            let active = store.isActive(ctx.branch, in: ctx.project)
            let dir = ctx.project.directory(for: ctx.branch)
            let status = store.gitStatus(for: ctx.branch, in: ctx.project)
            // La carpeta principal (para saber si hay un rebase o un merge a medias antes de hacer checkout).
            let mainStatus = store.dirStatus[ctx.project.path]
            let sessions = ctx.branch.activeSessions
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if ctx.project.isScratch {
                        ScratchHeader(directory: dir)
                    } else {
                        BranchHeader(project: ctx.project, branch: ctx.branch, status: status, directory: dir)
                    }

                    if !active {
                        let head = store.mainHeads[ctx.project.id] ?? ""
                        if let operation = mainStatus?.operation {
                            // Con un rebase o un merge a medias, git no deja cambiar de rama.
                            Callout(icon: "pause.circle.fill", color: Theme.attention,
                                    title: "Rama inactiva",
                                    text: "La carpeta principal está en «\(head)» con un \(operation.noun) a medias. Terminalo o cancelalo antes de hacer checkout.")
                        } else {
                            Callout(icon: "pause.circle.fill", color: Theme.attention,
                                    title: "Rama inactiva",
                                    text: "La carpeta principal está en «\(head)». Para trabajar acá hay que hacer checkout.",
                                    action: ("Hacer checkout", { store.requestCheckout(branchId: branchId) }))
                        }
                    }

                    if status?.isUnborn == true {
                        Callout(icon: "sparkles", color: .blue,
                                title: "Este repo todavía no tiene commits",
                                text: "Git necesita un primer commit para crear ramas y mostrar el historial. Podés crear uno vacío y seguir.",
                                action: ("Crear primer commit", { Task { await store.createFirstCommit(projectId: ctx.project.id) } }))
                    }

                    if sessions.isEmpty {
                        DetailSection("Nueva sesión") {
                            HStack(spacing: 10) {
                                ForEach(SessionKind.allCases) { kind in
                                    NewSessionCard(kind: kind) { store.requestNewSession(branchId: branchId, kind: kind) }
                                }
                            }
                            // Todas del alto de la más alta (la de un agente sin instalar suma una línea).
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        DetailSection("Sesiones", trailing: {
                            HStack(spacing: 6) {
                                ForEach(SessionKind.allCases) { kind in
                                    NewSessionPill(kind: kind, branchId: branchId)
                                }
                            }
                        }) {
                            LazyVGrid(columns: HiveCard.gridColumns, alignment: .leading, spacing: 12) {
                                ForEach(sessions) { session in
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
                        GitSections(git: store.git, status: status, directory: dir, active: active, branchName: ctx.branch.name,
                                    inactiveRefreshKey: RecentCommits.refreshKey(mainStatus))
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
            .navigationSubtitle(ctx.project.isScratch ? dir.tildePath : ctx.project.name)
            .task { AgentAvailability.shared(for: store).refresh() }
            // Al volver a Hive (por ejemplo, después de instalar un agente en la terminal).
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                AgentAvailability.shared(for: store).refresh()
            }
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        NewSessionItems(branchId: branchId)
                    } label: {
                        Label("Nueva sesión", systemImage: "plus")
                    }
                    .help("Nueva sesión en esta rama")
                    OpenInMenu(path: dir)
                }
            }
        }
    }
}

/// «Cambios · N» y «Últimos commits» (solo si la rama tiene checkout).
private struct GitSections: View {
    let git: GitClient
    let status: GitStatus?
    let directory: String
    let active: Bool
    let branchName: String
    /// En una rama inactiva, los commits se vuelven a leer cuando cambia la carpeta principal.
    let inactiveRefreshKey: String

    var body: some View {
        let count = status?.changes.count ?? 0
        DetailSection(count > 0 ? "Cambios · \(count)" : "Cambios") {
            Group {
                if let status {
                    ChangesList(status: status, directory: directory, showsHeaderWhenAlone: false)
                        .padding(.vertical, 4)
                } else {
                    Text(active ? "Sin información de git para esta rama." : "Sin checkout: los cambios se ven al abrirla.")
                        .font(HiveFont.secondary)
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .hiveCard()
        }

        DetailSection("Últimos commits") {
            Group {
                if active {
                    RecentCommits(git: git, directory: directory, refreshKey: RecentCommits.refreshKey(status))
                } else {
                    // La carpeta tiene otra rama: se leen los commits de esta por su nombre.
                    RecentCommits(git: git, directory: directory, ref: branchName, refreshKey: inactiveRefreshKey)
                }
            }
            .hiveCard()
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Terminales").font(HiveFont.title)
                Text("Terminales y agentes sueltos, fuera de cualquier repo. Arrancan en \(directory.tildePath).")
                    .font(HiveFont.secondary)
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(branch.name)
                        .font(HiveFont.title)
                        .textSelection(.enabled)
                    Chip(text: branch.mode == .worktree ? "Worktree" : "Carpeta principal")
                    ForEach(BranchGitBadges.make(status), id: \.text) { badge in
                        Chip(text: badge.text, help: badge.help)
                            .foregroundStyle(badge.warning ? AnyShapeStyle(Theme.attention) : AnyShapeStyle(.primary))
                    }
                }
                CopyablePath(path: directory)
            }
            Spacer(minLength: 12)
            // Abrir el sitio de la rama y traer, publicar o abrir el MR. Si no hay sitio ni remoto, no ocupan lugar.
            BranchWebActions(project: project, branch: branch)
        }
    }
}

/// Lo que el encabezado de una rama dice de git: commits sin pushear o sin traer, si la rama remota
/// que seguía ya no existe y si hay un rebase, merge o similar a medias.
enum BranchGitBadges {
    struct Badge: Equatable {
        let text: String
        let help: String
        /// Se muestra en naranja: hay algo que resolver.
        var warning = false
    }

    static func make(_ status: GitStatus?) -> [Badge] {
        guard let status else { return [] }
        var badges: [Badge] = []
        if let operation = status.operation {
            badges.append(Badge(text: operation.label, help: "Terminalo o cancelalo desde la terminal (o resolvé los conflictos en Cambios)",
                                warning: true))
        }
        if status.upstreamGone {
            badges.append(Badge(text: "Remota borrada", help: "La rama remota que seguía ya no existe (¿se mergeó el MR?)", warning: true))
        }
        if status.ahead > 0 { badges.append(Badge(text: "↑ \(status.ahead)", help: "Commits sin pushear")) }
        if status.behind > 0 { badges.append(Badge(text: "↓ \(status.behind)", help: "Commits sin traer")) }
        return badges
    }
}

/// «Abrir sitio» y el menú del remoto (GitLab o GitHub) de una rama, juntos. Van en el encabezado de
/// la rama y en la barra de la sesión.
struct BranchWebActions: View {
    let project: Project
    let branch: Branch

    var body: some View {
        HStack(spacing: 8) {
            OpenSiteButton(project: project, branch: branch)
                .fixedSize()
            RemoteActionsMenu(project: project, branch: branch)
                .fixedSize()
        }
    }
}
