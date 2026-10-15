import HiveCore
import SwiftUI

/// Buscador rápido (⌘K): proyectos, ramas, sesiones y comandos.
struct QuickSwitcher: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = SwitcherIndex.search(query, in: store.projects)
        VStack(spacing: 0) {
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
                Text("Sin resultados para «\(query)»")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                SwitcherRow(item: item, selected: i == index)
                                    .id(i)
                                    .onTapGesture {
                                        index = i
                                        open(results)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: index) { _, value in proxy.scrollTo(value) }
                }
                .frame(height: 380)
            }
            HStack(spacing: 14) {
                Label("navegar", systemImage: "arrow.up.arrow.down")
                Label("abrir", systemImage: "return")
                Label("cerrar", systemImage: "escape")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.03))
        }
        .frame(width: 580)
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    private func open(_ results: [SwitcherItem]) {
        guard results.indices.contains(index) else { return }
        let item = results[index]
        dismiss()
        switch item.target {
        case .project(let id): store.openProject(id)
        case .branch(let id): store.select(.branch(id))
        case .session(let id): store.select(.session(id))
        case .command(let project, let command): store.run(command, projectId: project)
        case .archivedSession, .action: break
        }
    }
}

private struct SwitcherRow: View {
    @Environment(AppStore.self) private var store
    let item: SwitcherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .session(let id) = item.target, let rt = store.runtimes[id], let ctx = store.sessionContext(id) {
                StatusIndicator(status: rt.status, unseen: rt.unseen, kind: ctx.session.kind)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
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
        case .command:
            Image(systemName: "play.fill")
                .foregroundStyle(.green)
        case .archivedSession, .action:
            EmptyView()
        }
    }
}
