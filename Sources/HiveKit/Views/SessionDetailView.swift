import HiveCore
import SwiftUI

struct SessionDetailView: View {
    @Environment(AppStore.self) private var store
    let sessionId: UUID
    /// Panel lateral abierto: "changes", "history" o "" (ninguno).
    @AppStorage("sessionSidePanel") private var sidePanel = ""

    var body: some View {
        if let ctx = store.sessionContext(sessionId), let rt = store.runtimes[sessionId] {
            let active = store.isActive(ctx.branch, in: ctx.project)
            let dir = ctx.project.directory(for: ctx.branch)
            // Panel propio en lugar de `.inspector`: el inspector se mete debajo de la barra de
            // herramientas y deja un hueco vacío arriba.
            HSplitView {
                VStack(spacing: 0) {
                    if rt.status == .dormant && !active {
                        InactiveBranchPlaceholder(project: ctx.project, branch: ctx.branch) {
                            store.openInactiveSession(sessionId)
                        }
                    } else {
                        if !active && rt.isRunning {
                            MovedHeadBanner(project: ctx.project, branch: ctx.branch)
                        }
                        TerminalContainer(terminal: rt.terminal)
                        if case .exited(let code) = rt.status {
                            ExitedBar(code: code, kind: ctx.session.kind) { store.relaunch(sessionId) }
                        }
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: TerminalTheme.background))

                if sidePanel == "changes" && !ctx.project.isScratch {
                    ChangesPanel(project: ctx.project, branch: ctx.branch)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 560, maxHeight: .infinity)
                } else if sidePanel == "history" {
                    HistoryPanel(session: ctx.session)
                        .frame(minWidth: 260, idealWidth: 360, maxWidth: 620, maxHeight: .infinity)
                }
            }
            .navigationTitle(ctx.session.name)
            .navigationSubtitle("\(ctx.project.name) › \(ctx.branch.name)")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 6) {
                        ProjectTile(project: ctx.project, size: 18)
                        AgentLogo(kind: ctx.session.kind, size: 16)
                    }
                }
                ToolbarItemGroup {
                    StatusPill(status: rt.status, kind: ctx.session.kind)
                    if rt.isRunning {
                        Button {
                            store.relaunch(sessionId)
                        } label: {
                            Label("Reiniciar", systemImage: "arrow.counterclockwise")
                        }
                        .help(ctx.session.kind.isAgent ? "Reiniciar (retoma la conversación)" : "Reiniciar la terminal")
                    }
                    OpenInMenu(path: dir)
                    if ctx.session.kind.isAgent {
                        Button {
                            sidePanel = sidePanel == "history" ? "" : "history"
                        } label: {
                            Label("Historial", systemImage: sidePanel == "history" ? "clock.arrow.circlepath.fill" : "clock.arrow.circlepath")
                        }
                        .help("Todo lo que se habló en esta sesión, también lo anterior a cada /clear")
                    }
                    if !ctx.project.isScratch {
                        Button {
                            sidePanel = sidePanel == "changes" ? "" : "changes"
                        } label: {
                            Label("Cambios", systemImage: "sidebar.right")
                        }
                        .help("Mostrar los cambios de git de esta rama")
                    }
                }
            }
            .task(id: sessionId) {
                store.activate(sessionId)
            }
        }
    }
}

private struct ExitedBar: View {
    let code: Int32?
    let kind: SessionKind
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
            Text(code == nil || code == 0 ? "La sesión terminó." : "La sesión terminó con código \(code!).")
            Spacer()
            Button(kind.isAgent ? "Reanudar conversación" : "Abrir de nuevo", action: onResume)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// La sesión corre en la carpeta principal, pero alguien hizo checkout de otra rama.
private struct MovedHeadBanner: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("La carpeta principal ahora está en «\(store.mainHeads[project.id] ?? "")»: esta sesión está viendo esa rama, no «\(branch.name)».")
                .font(.callout)
            Spacer()
            Button("Volver a «\(branch.name)»") { store.requestCheckout(branchId: branch.id) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

private struct InactiveBranchPlaceholder: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    let onCheckout: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Rama inactiva", systemImage: "arrow.triangle.branch")
        } description: {
            Text("Esta sesión trabaja en la carpeta principal, que ahora está en «\(store.mainHeads[project.id] ?? "")». Para abrirla hay que hacer checkout de «\(branch.name)».")
        } actions: {
            Button("Hacer checkout y abrir", action: onCheckout)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
