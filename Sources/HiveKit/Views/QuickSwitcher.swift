import HiveCore
import SwiftUI

/// Buscador rápido (⌘K): proyectos, ramas, sesiones, comandos y archivadas. Con «>» adelante
/// muestra acciones (sesiones y ramas nuevas, agregar proyecto, cambiar de vista, ajustes).
struct QuickSwitcher: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage("layout") private var layout: HiveLayout = .tree
    @State private var query: String
    @State private var index = 0
    /// Archivada elegida: la hoja muestra su historial en lugar de los resultados.
    @State private var archivedId: UUID?
    /// Lo que hay que hacer cuando se termine de cerrar la hoja (abrir otra hoja o un panel).
    @State private var afterDismiss: (() -> Void)?
    @FocusState private var focused: Bool

    init(query: String = "", archivedId: UUID? = nil) {
        _query = State(initialValue: query)
        _archivedId = State(initialValue: archivedId)
    }

    var body: some View {
        Group {
            if let id = archivedId, let ctx = store.sessionContext(id) {
                ArchivedSessionView(project: ctx.project, branch: ctx.branch, session: ctx.session) {
                    archivedId = nil
                    focused = true
                } onRestore: {
                    dismiss()
                    store.unarchive(id)
                    HiveNavigator.reveal(store, session: id)
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
        let groups = grouped(SwitcherIndex.search(query, in: store.projects, includeArchived: true, includeActions: true,
                                                  compactLayout: layout == .compact))
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
            }
            .padding(16)
            Divider()
            if results.isEmpty {
                VStack(spacing: 6) {
                    Text("Sin resultados para «\(query)»")
                    Text("Escribí «>» para ver acciones, como «>nueva claude».")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 140)
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
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "navegar")
            hint("↵", "abrir")
            hint("esc", "cerrar")
            Spacer()
            hint(">", "acciones")
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
            archivedId = id
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
        case .archivedSession:
            break
        case .action(let action):
            perform(action)
        }
    }

    private func perform(_ action: SwitcherAction) {
        switch action {
        case .newSession(let branch, let kind):
            // Si la rama no está activa pide el checkout con un diálogo: que aparezca con la hoja ya cerrada.
            afterDismiss = { [store] in store.requestNewSession(branchId: branch, kind: kind) }
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
            if let status {
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            } else if item.kind == .archived {
                Text("Ver historial")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(selected ? Color.honey.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.subtitle, status?.label].compactMap { $0 }.joined(separator: ", "))
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
            text[start..<end].backgroundColor = Color.honey.opacity(0.28)
        }
        return text
    }

    /// Punto y etiqueta del estado de una sesión (las dormidas no muestran nada).
    private var sessionStatus: (color: Color, label: String)? {
        guard case .session(let id) = item.target, let rt = store.runtimes[id] else { return nil }
        let label = rt.status.label(for: rt.kind)
        switch rt.status {
        case .dormant: return nil
        case .attention: return (.orange, label)
        case .waiting: return (rt.unseen ? .green : .green.opacity(0.5), label)
        case .working: return (.honey, label)
        case .idle, .exited: return (.secondary.opacity(0.6), label)
        }
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
        case .command:
            Image(systemName: "play.fill")
                .foregroundStyle(.green)
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
                    .buttonStyle(.borderedProminent)
                    .help("Vuelve a las pestañas y retoma la conversación")
            }
            .padding(12)
            Divider()
            HistoryPanel(session: session)
                .frame(height: 440)
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
