import AppKit
import HiveCore
import SwiftUI

/// Buscador rápido (⌘K): proyectos, ramas, sesiones, comandos y archivadas. Con «>» adelante
/// muestra acciones (sesiones y ramas nuevas, agregar proyecto, cambiar de vista, ajustes) y con
/// «?», lo que hablaste con Claude y Codex (el historial guardado de todas las sesiones). Es la única
/// búsqueda en todas las sesiones: el botón del panel de historial abre esta misma con «?».
struct QuickSwitcher: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage("layout") private var layout: HiveLayout = .tree
    @State private var query: String
    @State private var index = 0
    /// Archivada elegida: la hoja muestra su historial en lugar de los resultados.
    @State private var archivedId: UUID?
    /// El mensaje encontrado con «?» que llevó a la archivada: al restaurarla, abre en ese mensaje.
    @State private var archivedJump: HistoryJumpRequest.Jump?
    /// Lo que hay que hacer cuando se termine de cerrar la hoja (abrir otra hoja o un panel).
    @State private var afterDismiss: (() -> Void)?
    /// Con «?»: lo que se encontró en el historial (se busca fuera del hilo principal).
    @State private var historyHits: [HistoryStore.SearchHit] = []
    @State private var searchingHistory = false
    @FocusState private var focused: Bool

    /// Cuántos mensajes del historial muestra el buscador como mucho (la lista es perezosa: no pesa).
    static let historyLimit = 200

    init(query: String = "", archivedId: UUID? = nil) {
        _query = State(initialValue: query)
        _archivedId = State(initialValue: archivedId)
    }

    var body: some View {
        Group {
            if let id = archivedId, let ctx = store.sessionContext(id) {
                ArchivedSessionView(project: ctx.project, branch: ctx.branch, session: ctx.session) {
                    archivedId = nil
                    archivedJump = nil
                    focused = true
                } onRestore: {
                    // Si se llegó desde un mensaje encontrado con «?», la sesión abre con el historial en ese
                    // mensaje. Se restaura con la hoja ya cerrada: si no, el salto se lo quedaría el historial
                    // de adentro (el de esta hoja, que muestra la misma sesión).
                    let jump = archivedJump
                    afterDismiss = { [store] in HiveNavigator.restoreArchived(store, session: id, jump: jump) }
                    dismiss()
                }
            } else {
                search
            }
        }
        .frame(width: 600)
        .onDisappear { afterDismiss?() }
    }

    // MARK: Resultados

    private var search: some View {
        let historyText = SwitcherIndex.historyQuery(query)
        let found = historyText.map { SwitcherIndex.historyItems(historyHits, query: $0, in: store.projects) }
            // Los proyectos en el orden que se ve en el riel y en el árbol (fijados, activos, apagados).
            ?? SwitcherIndex.search(query, in: HiveNavigator.orderedProjects(store), includeArchived: true, includeActions: true,
                                    compactLayout: layout == .compact, missingAgents: AgentAvailability.shared(for: store).missing)
        let groups = grouped(found)
        let results = groups.flatMap(\.items)
        let showHeaders = groups.count > 1
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Buscar proyecto, rama, sesión o comando", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { open(results) }
                    .onKeyPress(.downArrow) {
                        index = min(index + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        index = max(index - 1, 0)
                        return .handled
                    }
                    .onExitCommand { dismiss() }
                    // Con «?validación» ya escrito (el botón del panel de historial), lo primero que tipees
                    // sigue la búsqueda en lugar de reemplazarla entera, «?» incluido.
                    .background(CaretAtEnd(focused: focused, text: query))
                if searchingHistory {
                    ProgressView().controlSize(.small)
                } else if let historyText, historyText.count >= 2, !results.isEmpty {
                    Text(historyHits.count >= Self.historyLimit ? "\(Self.historyLimit)+ resultados"
                         : results.count == 1 ? "1 resultado" : "\(results.count) resultados")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(16)
            Divider()
            if results.isEmpty {
                emptyState(historyText)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(groups, id: \.kind) { group in
                                if showHeaders {
                                    Text(group.kind.header)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, group.kind == groups.first?.kind ? 2 : 10)
                                        .padding(.bottom, 2)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                ForEach(group.items) { item in
                                    let position = results.firstIndex(of: item) ?? 0
                                    Button {
                                        index = position
                                        open(results)
                                    } label: {
                                        SwitcherRow(item: item, query: query, selected: position == index)
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: index) { _, value in
                        if results.indices.contains(value) { proxy.scrollTo(results[value].id) }
                    }
                }
                .frame(height: 400)
            }
            footer
        }
        .onAppear {
            focused = true
            // Que las acciones de «Nueva sesión» no digan «No instalado» de algo que ya instalaste.
            AgentAvailability.shared(for: store).refreshIfStale()
        }
        .onChange(of: query) { index = 0 }
        .task(id: historyText) { await searchHistory(historyText) }
    }

    private func emptyState(_ historyText: String?) -> some View {
        VStack(spacing: 6) {
            if let historyText {
                if historyText.count < 2 {
                    Text("Buscá en lo que hablaste con Claude y Codex")
                    Text("Escribí al menos dos letras después de «?». También busca en las sesiones archivadas.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                } else if searchingHistory {
                    Text("Buscando en el historial…")
                } else {
                    Text("Nada en el historial coincide con «\(historyText)»")
                }
            } else {
                Text("Sin resultados para «\(query)»")
                Text("Escribí «>» para ver acciones, como «>nueva claude», o «?» para buscar en el historial.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    /// Con «?», busca en el historial guardado fuera del hilo principal, con una pausa corta para no
    /// buscar en cada tecla.
    private func searchHistory(_ text: String?) async {
        guard let text, text.count >= 2 else {
            historyHits = []
            searchingHistory = false
            return
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        searchingHistory = true
        let ids = SwitcherIndex.historySessionIds(store.projects)
        let history = store.history
        let limit = Self.historyLimit
        let hits = await Task.detached(priority: .userInitiated) { history.search(text, sessionIds: ids, limit: limit) }.value
        guard !Task.isCancelled else { return }
        historyHits = hits
        searchingHistory = false
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "navegar")
            hint("↵", "abrir")
            hint("esc", "cerrar")
            Spacer()
            hint(">", "acciones")
            hint("?", "historial")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Keycap(key)
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }

    /// Agrupa por tipo, en el orden en que aparece el mejor resultado de cada uno.
    private func grouped(_ results: [SwitcherItem]) -> [(kind: SwitcherItem.Kind, items: [SwitcherItem])] {
        var groups: [(kind: SwitcherItem.Kind, items: [SwitcherItem])] = []
        for item in results {
            if let i = groups.firstIndex(where: { $0.kind == item.kind }) {
                groups[i].items.append(item)
            } else {
                groups.append((item.kind, [item]))
            }
        }
        return groups
    }

    // MARK: Abrir

    private func open(_ results: [SwitcherItem]) {
        guard results.indices.contains(index) else { return }
        let item = results[index]
        if case .archivedSession(let id) = item.target {
            archivedJump = nil
            archivedId = id
            return
        }
        if case .historyEntry(let session, let entry) = item.target {
            // Una archivada no se abre: su historial se ve en la misma hoja, ya en esa entrada.
            let text = SwitcherIndex.historyQuery(query) ?? ""
            if HiveNavigator.openHistoryEntry(store, session: session, entry: entry, query: text) {
                dismiss()
            } else {
                archivedJump = .init(sessionId: session, entryId: entry, query: text)
                archivedId = session
            }
            return
        }
        dismiss()
        switch item.target {
        case .project(let id):
            HiveNavigator.open(store, project: id)
        case .branch(let id):
            if let ctx = store.branchContext(id) { store.setExpanded(ctx.project.id, true) }
            store.select(.branch(id))
        case .session(let id):
            HiveNavigator.reveal(store, session: id)
        case .command(let project, let command):
            store.run(command, projectId: project)
        case .archivedSession, .historyEntry:
            break
        case .action(let action):
            perform(action)
        }
    }

    private func perform(_ action: SwitcherAction) {
        switch action {
        case .newSession(let branch, let kind):
            // Si la rama no está activa pide el checkout con un diálogo: que aparezca con la hoja ya cerrada.
            // Lo mismo el aviso de un agente que no está instalado.
            afterDismiss = { [store] in HiveNavigator.requestNewSession(store, branchId: branch, kind: kind) }
        case .newBranch(let project):
            // Otra hoja: se abre cuando termina de cerrarse esta.
            afterDismiss = { [store] in store.newBranchTarget = NewBranchTarget(id: project) }
        case .addProject:
            afterDismiss = { [store] in store.addProjectInteractive() }
        case .setLayout(let compact):
            layout = compact ? .compact : .tree
        case .settings:
            afterDismiss = { [openSettings] in openSettings() }
        }
    }
}

// MARK: - Fila

private struct SwitcherRow: View {
    @Environment(AppStore.self) private var store
    let item: SwitcherItem
    let query: String
    let selected: Bool

    var body: some View {
        let status = sessionStatus
        let statusText = status.map { StatusStyle.of(status: $0.status, unseen: $0.unseen, kind: $0.kind).text }
        HStack(spacing: 10) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(item.title))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let status, let statusText {
                // El mismo ícono que en el sidebar y las tarjetas.
                HStack(spacing: 5) {
                    StatusIndicator(status: status.status, unseen: status.unseen, kind: status.kind)
                        .accessibilityHidden(true)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .fixedSize()
            } else if item.kind == .archived {
                Text("Ver historial")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else if item.kind == .history {
                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(selected ? Theme.accentFill.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.subtitle, status.map { StatusIndicator.accessibilityText(status: $0.status, unseen: $0.unseen, kind: $0.kind) }]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Las letras que coinciden con la búsqueda, en negrita y marcadas.
    private func highlighted(_ title: String) -> AttributedString {
        var text = AttributedString(title)
        let characters = text.characters
        for range in SwitcherIndex.highlights(query, in: title) where range.upperBound <= characters.count {
            let start = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let end = characters.index(characters.startIndex, offsetBy: range.upperBound)
            text[start..<end].font = .system(size: 13.5, weight: .bold)
            text[start..<end].backgroundColor = Theme.accentFill.opacity(0.35)
        }
        return text
    }

    /// El estado de una sesión (las dormidas no muestran nada).
    private var sessionStatus: (status: SessionStatus, unseen: Bool, kind: SessionKind)? {
        guard case .session(let id) = item.target, let rt = store.runtimes[id], rt.status != .dormant else { return nil }
        return (rt.status, rt.unseen, rt.kind)
    }

    @ViewBuilder private var icon: some View {
        switch item.target {
        case .project(let id):
            if let project = store.project(id) { ProjectTile(project: project, size: 22) }
        case .branch(let id):
            if let ctx = store.branchContext(id) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle((ctx.branch.color ?? ctx.project.tint).color)
            }
        case .session(let id):
            if let ctx = store.sessionContext(id) { AgentLogo(kind: ctx.session.kind, size: 20) }
        case .archivedSession(let id):
            if let ctx = store.sessionContext(id) {
                AgentLogo(kind: ctx.session.kind, size: 20)
                    .saturation(0)
                    .opacity(0.6)
            }
        case .historyEntry(let id, _):
            if let ctx = store.sessionContext(id) {
                AgentLogo(kind: ctx.session.kind, size: 20)
                    .saturation(ctx.session.isArchived ? 0 : 1)
                    .opacity(ctx.session.isArchived ? 0.6 : 1)
            }
        case .command:
            Image(systemName: "play.fill")
                .foregroundStyle(Theme.running)
        case .action(let action):
            switch action {
            case .newSession(_, let kind):
                AgentLogo(kind: kind, size: 20)
            case .newBranch:
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            case .addProject:
                Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
            case .setLayout(let compact):
                Image(systemName: compact ? "rectangle.split.3x1" : "list.bullet.indent").foregroundStyle(.secondary)
            case .settings:
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Historial de una archivada

/// El historial de una sesión archivada, en la misma hoja del buscador.
private struct ArchivedSessionView: View {
    let project: Project
    let branch: Branch
    let session: Session
    let onBack: () -> Void
    let onRestore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Label("Volver", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Volver a los resultados (esc)")
                Spacer(minLength: 8)
                AgentLogo(kind: session.kind, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Archivada · \(project.isScratch ? project.name : "\(project.name) › \(branch.name)")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Restaurar", action: onRestore)
                    .buttonStyle(.hiveProminent)
                    .help("Vuelve a las pestañas y retoma la conversación")
            }
            .padding(12)
            Divider()
            // Ya estás en ⌘K: el panel no ofrece abrirlo otra vez encima.
            HistoryPanel(session: session, showsGlobalSearch: false)
                .frame(height: 440)
        }
    }
}

/// Deja el cursor al final del campo cuando toma el foco. macOS selecciona todo el texto al enfocar
/// un campo: con «?validación» seleccionado, la primera tecla lo reemplazaría y se perdería el «?».
private struct CaretAtEnd: NSViewRepresentable {
    let focused: Bool
    /// Lo que tiene el campo al tomar el foco.
    let text: String

    @MainActor final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        defer { coordinator.wasFocused = focused }
        // Solo al tomar el foco: después, lo que selecciones vos queda como lo dejaste. Con el campo
        // vacío no hay nada que cuidar.
        guard focused, !coordinator.wasFocused, !text.isEmpty else { return }
        let expected = text
        Task { @MainActor [weak view] in
            // SwiftUI le da el foco y el texto al campo un rato después: con la máquina cargada, el editor
            // puede aparecer antes que el texto, o tardar varios segundos. Se espera a que el editor muestre
            // el texto (si no, el cursor quedaría al principio, antes del «?»), mientras el campo siga con
            // el foco y como mucho 30 s.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, coordinator.wasFocused, let window = view?.window {
                if let editor = window.firstResponder as? NSTextView, editor.string == expected {
                    editor.setSelectedRange(NSRange(location: (expected as NSString).length, length: 0))
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}

/// Una tecla dibujada como en el teclado («↵», «esc»).
private struct Keycap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 17)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }
}
