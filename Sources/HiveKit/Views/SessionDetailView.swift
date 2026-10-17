import AppKit
import HiveCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let sessionId: UUID
    /// Panel lateral abierto: "changes", "history" o "" (ninguno).
    @AppStorage("sessionSidePanel") private var sidePanel = ""
    @AppStorage(TerminalPreferences.themeKey) private var terminalTheme = TerminalPreferences.Theme.system.rawValue
    /// «Abrir sitio» y el menú del remoto se leen acá, antes de ponerlos en la barra: un botón que
    /// todavía no sabe si va (o que no va) dejaba una cápsula de vidrio vacía en la barra de macOS.
    /// Se guardan con la carpeta y el repo para los que se leyeron (al cambiar de sesión no se
    /// muestra el de la anterior).
    @State private var site: SessionLoaded<String>?
    @State private var remote: SessionLoaded<RemoteInfo>?
    var usage: UsageMonitor = .shared

    var body: some View {
        if let ctx = store.sessionContext(sessionId), let rt = store.runtimes[sessionId] {
            let active = store.isActive(ctx.branch, in: ctx.project)
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
                        if let draft = ctx.session.recoveredDraft {
                            RecoveredDraftBanner(sessionId: sessionId, draft: draft)
                        }
                        TerminalContainer(terminal: rt.terminal)
                            .background(terminalBackground)
                            .disabled(rt.isSwitchingAgent)
                            .overlay {
                                if rt.isSwitchingAgent {
                                    ProgressView("Guardando contexto y cambiando de IA…")
                                        .padding(20)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                }
                                // Mientras se arma el lanzamiento (búsquedas en disco), algo que diga que viene.
                                if rt.isLaunching && rt.terminal == nil {
                                    LaunchingIndicator(kind: ctx.session.kind)
                                        .environment(\.colorScheme, terminalIsLight ? .light : .dark)
                                }
                            }
                        if case .exited(let code) = rt.status {
                            ExitedBar(code: code, kind: ctx.session.kind, processStarted: rt.terminal?.hasStartedProcess ?? false,
                                      startupFailure: rt.startupFailure) {
                                store.relaunch(sessionId)
                            }
                        }
                    }
                    SessionStatusBar(project: ctx.project, branch: ctx.branch)
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .background(terminalBackground)

                if sidePanel == "changes" && !ctx.project.isScratch {
                    ChangesPanel(project: ctx.project, branch: ctx.branch)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 560, maxHeight: .infinity)
                } else if sidePanel == "history" {
                    HistoryPanel(session: ctx.session)
                        .frame(minWidth: 260, idealWidth: 360, maxWidth: 620, maxHeight: .infinity)
                }
            }
            .navigationTitle(ctx.session.name)
            .navigationSubtitle(ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 6) {
                        ProjectTile(project: ctx.project, size: 18)
                        if ctx.session.kind.reportsConversation {
                            SessionAgentMenu(session: ctx.session, runtime: rt, active: active)
                        } else {
                            AgentLogo(kind: ctx.session.kind, size: 16)
                        }
                    }
                }
                ToolbarItemGroup {
                    StatusPill(status: rt.status, unseen: rt.unseen, kind: ctx.session.kind, background: rt.backgroundAgents > 0)
                    // Cuánto contexto ocupa, en Claude y Codex (nada mientras no informen).
                    if usage.sessions[sessionId]?.agent == ctx.session.kind, usage.sessions[sessionId]?.contextPercent != nil {
                        UsageBadge(sessionId: sessionId, monitor: usage)
                    }
                }
                ToolbarItemGroup {
                    SessionPanelToggles(sidePanel: $sidePanel, showsChanges: !ctx.project.isScratch)
                        .padding(.leading, 8)
                    NewSessionMenu(branchId: ctx.branch.id, kind: ctx.session.kind)
                        .labelStyle(.titleAndIcon)
                        .padding(.leading, 4)
                }
                ToolbarItemGroup {
                    if !ctx.project.isScratch {
                        SessionCommandsMenu(project: ctx.project, branch: ctx.branch)
                            .labelStyle(.titleAndIcon)
                            .padding(.leading, 8)
                        if let url = site?.value(for: ctx.project.directory(for: ctx.branch)) {
                            OpenSiteButton(project: ctx.project, branch: ctx.branch, url: url)
                                .labelStyle(.titleAndIcon)
                        }
                        if let info = remote?.value(for: ctx.project.path) {
                            RemoteActionsMenu(project: ctx.project, branch: ctx.branch, info: info)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                ToolbarItemGroup {
                    Button {
                        rt.terminal?.openFindBar()
                    } label: {
                        Label("Buscar", systemImage: "magnifyingglass")
                    }
                    .labelStyle(.titleAndIcon)
                    .padding(.leading, 8)
                    .help("Buscar en la terminal, también en el scroll (⌘F)")
                    .accessibilityLabel("Buscar en la terminal")
                    .disabled(rt.terminal == nil)
                    SessionMoreMenu(session: ctx.session, runtime: rt, directory: ctx.project.directory(for: ctx.branch))
                        .labelStyle(.titleAndIcon)
                }
            }
            .task(id: sessionId) {
                store.activate(sessionId)
                usage.attach(store)
            }
            .onChange(of: ctx.session.kind) { usage.refresh() }
            .task(id: ctx.project.isScratch ? "" : ctx.project.directory(for: ctx.branch)) {
                guard !ctx.project.isScratch else { return }
                let dir = ctx.project.directory(for: ctx.branch)
                let url = await OpenSiteButton.loadURL(project: ctx.project, branch: ctx.branch, home: store.environment.home)
                site = SessionLoaded(key: dir, value: url)
            }
            .task(id: ctx.project.isScratch ? "" : ctx.project.path) {
                guard !ctx.project.isScratch else { return }
                let path = ctx.project.path
                remote = SessionLoaded(key: path, value: await RemoteInfo.load(git: store.git, path: path))
            }
            .task(id: store.focusTerminalRequest) {
                guard store.focusTerminalRequest == sessionId else { return }
                await focusTerminal()
            }
        }
    }

    /// Le da el foco a la terminal cuando ya está en la ventana. Puede no estar todavía (se está
    /// lanzando) o la hoja de ⌘K puede estar cerrándose: se reintenta un ratito.
    private func focusTerminal() async {
        for _ in 0..<40 {
            if let terminal = store.runtimes[sessionId]?.terminal, let window = terminal.window, window.attachedSheet == nil {
                window.makeFirstResponder(terminal)
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
        }
        store.consumeTerminalFocus(sessionId)
    }

    /// Si la terminal usa la paleta clara (según el ajuste y el sistema).
    private var terminalIsLight: Bool {
        switch TerminalPreferences.Theme(rawValue: terminalTheme) ?? .system {
        case .light: true
        case .dark: false
        case .system: colorScheme == .light
        }
    }

    /// El mismo fondo que la terminal (oscuro o claro según el ajuste y el sistema).
    private var terminalBackground: Color {
        Color(nsColor: terminalIsLight ? TerminalPalette.light.background : TerminalPalette.dark.background)
    }
}

/// Cambia la IA de esta misma conversación; «Nueva sesión» sigue creando una conversación aparte.
struct SessionAgentMenu: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let runtime: SessionRuntime
    let active: Bool

    var body: some View {
        let availability = AgentAvailability.shared(for: store)
        Menu {
            Section("Continuar esta conversación con") {
                ForEach(SessionKind.allCases.filter { $0.reportsConversation && $0 != session.kind }) { kind in
                    Button {
                        store.requestSwitchAgent(session.id, to: kind)
                    } label: {
                        Label {
                            Text(availability.isInstalled(kind) ? kind.label : "\(kind.label) (no instalado)")
                        } icon: {
                            Image(nsImage: AgentLogo.menuImage(kind))
                        }
                    }
                }
            }
            Text("Conserva el historial de esta sesión")
        } label: {
            Label {
                Text(session.kind.defaultName)
            } icon: {
                AgentLogo(kind: session.kind, size: 16)
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(!active || runtime.isLaunching || runtime.isSwitchingAgent)
        .help("Cambiar de IA y continuar con el historial de esta conversación")
    }
}

/// «Abriendo Claude Code…»: mientras se arma el lanzamiento y todavía no hay terminal.
struct LaunchingIndicator: View {
    let kind: SessionKind

    var body: some View {
        VStack(spacing: 10) {
            AgentLogo(kind: kind, size: 28)
            ProgressView()
                .controlSize(.small)
            Text("Abriendo \(kind.label)…")
                .font(HiveFont.secondary)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Abriendo \(kind.label)")
    }
}

// MARK: - Barra de herramientas

/// Algo que se leyó en segundo plano para una carpeta o un repo (`key`).
struct SessionLoaded<Value: Sendable>: Sendable {
    let key: String
    let value: Value?

    /// El valor, si se leyó para esta clave.
    func value(for key: String) -> Value? { self.key == key ? value : nil }
}

/// Historial y Cambios: dos botones que se excluyen. Tocar el activo cierra el panel. La cantidad
/// de cambios no va acá: ya está en la barra de abajo («2 cambios»), que abre el mismo panel.
private struct SessionPanelToggles: View {
    @Binding var sidePanel: String
    let showsChanges: Bool

    var body: some View {
        ControlGroup {
            Toggle(isOn: panel("history")) {
                Label("Historial", systemImage: "clock.arrow.circlepath")
            }
            .labelStyle(.titleAndIcon)
            .help("Todo lo que se habló en esta sesión, también lo anterior a cada /clear")
            if showsChanges {
                Toggle(isOn: panel("changes")) {
                    Label("Cambios", systemImage: GitCounters.changesSymbol)
                }
                .labelStyle(.titleAndIcon)
                .help("Cambios de git de esta rama")
            }
        }
    }

    private func panel(_ name: String) -> Binding<Bool> {
        Binding(get: { sidePanel == name }, set: { sidePanel = $0 ? name : "" })
    }
}

/// «Nueva sesión»: el clic crea otra del mismo agente en la rama; la flechita deja elegir otro.
private struct NewSessionMenu: View {
    @Environment(AppStore.self) private var store
    let branchId: UUID
    let kind: SessionKind

    var body: some View {
        Menu {
            NewSessionItems(branchId: branchId)
        } label: {
            Label("Nueva sesión", systemImage: "plus")
        } primaryAction: {
            HiveNavigator.requestNewSession(store, branchId: branchId, kind: kind)
        }
        .help("Nueva sesión de \(kind.label) en esta rama (con la flechita elegís otro agente)")
    }
}

/// Los comandos del proyecto para esta rama: ejecutar o detener cada uno.
private struct SessionCommandsMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch

    var body: some View {
        let anyRunning = project.commands.contains { store.runningRun(commandId: $0.id, branchId: branch.id) != nil }
        Menu {
            if project.commands.isEmpty {
                Text("Este proyecto no tiene comandos")
            }
            ForEach(project.commands) { command in
                if let running = store.runningRun(commandId: command.id, branchId: branch.id) {
                    Button {
                        store.stopRun(running.id)
                    } label: {
                        Label("Detener «\(command.name)»", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        store.run(command.id, projectId: project.id, branchId: branch.id)
                    } label: {
                        Label("Ejecutar «\(command.name)»", systemImage: "play.fill")
                    }
                }
            }
            Divider()
            Button("Editar comandos…") { store.select(.project(project.id)) }
        } label: {
            Label("Comandos", systemImage: anyRunning ? "play.circle.fill" : "play.circle")
        }
        .help(anyRunning ? "Comandos del proyecto (hay alguno corriendo en esta rama)" : "Comandos del proyecto")
    }
}

/// Lo menos frecuente de la sesión: reiniciar, copiar o guardar el texto, abrir en, detener y archivar.
private struct SessionMoreMenu: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let runtime: SessionRuntime
    let directory: String

    var body: some View {
        Menu {
            if runtime.isRunning {
                Button(session.kind.isAgent ? "Reiniciar (retoma la conversación)" : "Reiniciar la terminal") {
                    store.requestRestart(session.id)
                }
            }
            Divider()
            Button("Copiar todo el texto de la terminal") {
                ExternalApps.copyToPasteboard(runtime.terminal?.fullText() ?? "")
            }
            .disabled(runtime.terminal == nil)
            Button("Guardar como .txt…") { saveText() }
                .disabled(runtime.terminal == nil)
            Menu("Abrir en") {
                OpenInItems(path: directory)
            }
            Divider()
            if runtime.isRunning {
                Button("Detener") { store.requestStop(session.id) }
            }
            Button("Archivar") { store.requestArchive(session.id) }
        } label: {
            Label("Acciones", systemImage: "ellipsis.circle")
        }
        .help("Más acciones de la sesión")
    }

    private func saveText() {
        guard let text = runtime.terminal?.fullText() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(session.name).txt"
        panel.prompt = "Guardar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.alert = AppAlert(title: "No pude guardar el texto", message: error.localizedDescription)
        }
    }
}

extension HiveTerminalView {
    /// Abre la barra de búsqueda de SwiftTerm (busca también en el scroll).
    func openFindBar() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }
}

// MARK: - Barras de aviso

/// La sesión terminó. Si es un agente que no está instalado, explica cómo instalarlo.
private struct ExitedBar: View {
    @Environment(AppStore.self) private var store
    let code: Int32?
    let kind: SessionKind
    /// Si la terminal llegó a lanzar el proceso (entonces el programa existía).
    let processStarted: Bool
    let startupFailure: CodexStartupFailure?
    let onResume: () -> Void
    @State private var missing = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            if startupFailure != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex no pudo iniciar").fontWeight(.semibold)
                    Text("Se agotó el tiempo al consultar tu cuenta. Podés reintentar en este mismo chat.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reintentar", action: onResume)
                    .buttonStyle(.hiveProminent)
                    .keyboardShortcut(.defaultAction)
            } else if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                Text("No encuentro \(kind.label)")
                Spacer()
                Button(copied ? "Copiado" : "Copiar comando de instalación") {
                    ExternalApps.copyToPasteboard(kind.installHint)
                    copied = true
                }
                .help(kind.installHint)
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
                Button("Reintentar", action: onResume)
                    .buttonStyle(.hiveProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
                Text(code == nil || code == 0 ? "La sesión terminó." : "La sesión terminó con código \(code!).")
                Spacer()
                Button(kind.isAgent ? "Reanudar conversación" : "Abrir de nuevo", action: onResume)
                    .buttonStyle(.hiveProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        // También con `processStarted`: al reintentar, la terminal nueva puede terminar con el mismo
        // código (nil) sin que la barra se vuelva a crear.
        .task(id: ExitKey(code: code, processStarted: processStarted)) {
            let environment = store.environment
            let path = environment.cachedLoginPATH
                ?? LoginShell.fallbackPATH(home: environment.home.path, inherited: environment.inheritedEnvironment["PATH"])
            missing = MissingAgent.isMissing(kind: kind, exitCode: code, processStarted: processStarted) {
                environment.processes.resolve($0, path: path)
            }
        }
    }

    private struct ExitKey: Equatable {
        let code: Int32?
        let processStarted: Bool
    }
}

/// Si una sesión que terminó es de un agente que no está instalado.
enum MissingAgent {
    /// Solo cuenta un agente cuyo proceso nunca arrancó y cuyo programa no está en el PATH. Si
    /// arrancó, existía: salir con un código (/quit) o por una señal (Detener, un cierre forzado,
    /// que llegan sin código) no quiere decir que falte. El PATH guardado puede ser el de la vez
    /// anterior y no tener, por ejemplo, la carpeta de nvm donde está Codex.
    static func isMissing(kind: SessionKind, exitCode: Int32?, processStarted: Bool, resolve: (String) -> String?) -> Bool {
        guard kind.isAgent, !processStarted, exitCode == nil, let binary = kind.binary else { return false }
        return resolve(binary) == nil
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
                .foregroundStyle(Theme.danger)
            Text("La carpeta principal ahora está en «\(store.mainHeads[project.id] ?? "")»: esta sesión está viendo esa rama, no «\(branch.name)».")
                .font(.callout)
            Spacer()
            Button("Volver a «\(branch.name)»") { store.requestCheckout(branchId: branch.id) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.danger.opacity(0.1))
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
                .buttonStyle(.hiveProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
