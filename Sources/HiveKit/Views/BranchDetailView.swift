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
            // Una sola fuente para el chip del encabezado, el aviso y lo que se ofrece hacer.
            let situation = BranchSituation.of(mode: ctx.branch.mode, active: active, missing: store.isMissing(ctx.branch),
                                               mainBusy: mainStatus?.operation != nil)
            let sessions = ctx.branch.activeSessions
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if ctx.project.isScratch {
                        ScratchHeader(directory: dir)
                    } else {
                        BranchHeader(project: ctx.project, branch: ctx.branch, status: status, directory: dir, situation: situation)
                    }

                    if situation == .missing {
                        // Sin nada corriendo, la próxima revisión de git la saca sola: el aviso queda para
                        // las que todavía tienen una sesión o un comando andando.
                        Callout(icon: "exclamationmark.triangle.fill", color: Theme.attention,
                                title: "No encuentro la carpeta de este worktree",
                                text: store.hasRunningWork(ctx.branch)
                                    ? "Se borró o se movió por fuera de Hive. Como todavía hay algo corriendo acá, la rama se va sola de Hive cuando termine. La rama de git no se borra."
                                    : "Se borró o se movió por fuera de Hive. Si ya no la usás, quitá la rama de Hive (la rama de git no se borra).",
                                action: ("Quitar de Hive…", { store.requestRemoval(.branch(branchId)) }))
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
                        // Sin carpeta o con un rebase a medias, una sesión nueva no podría arrancar: el aviso
                        // de arriba dice qué hacer.
                        if situation.canStartSessions {
                            DetailSection("Nueva sesión") {
                                HStack(spacing: 10) {
                                    ForEach(SessionKind.allCases) { kind in
                                        NewSessionCard(kind: kind) { store.requestNewSession(branchId: branchId, kind: kind) }
                                    }
                                }
                                // Todas del alto de la más alta (la de un agente sin instalar suma una línea).
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        DetailSection("Sesiones", trailing: {
                            if situation.canStartSessions {
                                HStack(spacing: 6) {
                                    ForEach(SessionKind.allCases) { kind in
                                        NewSessionPill(kind: kind, branchId: branchId)
                                    }
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

                    // Sin checkout, un comando correría en la carpeta principal con otra rama (o en ninguna).
                    if !ctx.project.commands.isEmpty && !ctx.project.isScratch && situation.hasCheckout {
                        DetailSection("Comandos") {
                            CommandsSection(project: ctx.project, branch: ctx.branch, editable: false)
                        }
                    }

                    if !ctx.project.isScratch && situation != .missing {
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
                    if situation.canStartSessions {
                        Menu {
                            NewSessionItems(branchId: branchId)
                        } label: {
                            Label("Nueva sesión", systemImage: "plus")
                        }
                        .help("Nueva sesión en esta rama")
                    }
                    if situation.hasFolder {
                        OpenInMenu(path: dir)
                    }
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
    let situation: BranchSituation

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
                    Chip(text: situation.label, help: situationHelp)
                        .foregroundStyle(situation.isWarning ? AnyShapeStyle(Theme.attention) : AnyShapeStyle(.primary))
                    ForEach(BranchGitBadges.make(status), id: \.text) { badge in
                        Chip(text: badge.text, help: badge.help)
                            .foregroundStyle(badge.warning ? AnyShapeStyle(Theme.attention) : AnyShapeStyle(.primary))
                    }
                }
                CopyablePath(path: directory)
            }
            Spacer(minLength: 12)
            // Abrir el sitio de la rama y traer, publicar o abrir el MR. Si no hay sitio ni remoto, no ocupan lugar.
            // Sin checkout, el sitio mostraría otra rama: queda solo el remoto (publicar y el MR andan
            // igual). Sin carpeta no se ofrece nada: la única salida es «Quitar de Hive…».
            if situation.hasCheckout {
                BranchWebActions(project: project, branch: branch)
            } else if situation.offersRemoteActions {
                RemoteActionsMenu(project: project, branch: branch)
                    .fixedSize()
            }
        }
    }

    private var situationHelp: String {
        switch situation {
        case .worktree: "Worktree en su propia carpeta"
        case .main: "Tiene el checkout en la carpeta principal"
        case .inactive, .blocked: "La carpeta principal está en otra rama"
        case .missing: "La carpeta de este worktree ya no está"
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
