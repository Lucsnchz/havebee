import HiveCore
import Observation
import SwiftUI

/// Pedido para que el panel de historial de una sesión muestre una búsqueda y salte a una entrada
/// (lo deja «Buscar en todas las sesiones» antes de abrir la sesión).
@Observable @MainActor
final class HistoryJumpRequest {
    struct Jump: Equatable {
        let sessionId: UUID
        let entryId: UUID
        let query: String
    }

    static let shared = HistoryJumpRequest()
    var pending: Jump?
}

/// Hoja «Buscar en todas las sesiones»: busca en el historial guardado de todos los proyectos,
/// también en el de las sesiones archivadas.
struct HistorySearchView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var initialQuery = ""
    @State private var query = ""
    @State private var hits: [HistoryStore.SearchHit] = []
    @State private var searching = false
    @State private var selection: String?
    @State private var archivedChoice: HistoryStore.SearchHit?
    @State private var reading: Session?
    @FocusState private var focused: Bool
    /// El panel lateral de la sesión (lo lee SessionDetailView): al abrir un resultado, el historial.
    @AppStorage("sessionSidePanel") private var sidePanel = ""

    static let limit = 200

    var body: some View {
        VStack(spacing: 0) {
            if let session = reading {
                readingBar(session)
                Divider()
                HistoryPanel(session: session, showsGlobalSearch: false)
            } else {
                searchBar
                Divider()
                results
            }
        }
        .frame(width: 640, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if query.isEmpty { query = initialQuery }
            focused = true
        }
        .task(id: query) { await search() }
        .alert("La sesión está archivada", isPresented: Binding(get: { archivedChoice != nil }, set: { if !$0 { archivedChoice = nil } }),
               presenting: archivedChoice) { hit in
            Button("Restaurar y abrir") { open(hit, restore: true) }
            Button("Solo ver el historial") { showArchived(hit) }
            Button("Cancelar", role: .cancel) {}
        } message: { hit in
            Text("«\(store.sessionContext(hit.sessionId)?.session.name ?? "Sesión")» está archivada. Podés restaurarla (vuelve a la rama y retoma la conversación) o leer su historial sin abrirla.")
        }
    }

    // MARK: - Partes

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("Buscar en todas las sesiones", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit { if let first = hits.first { choose(first) } }
            if searching {
                ProgressView().controlSize(.small)
            } else if !trimmedQuery.isEmpty {
                Text(hits.count >= Self.limit ? "\(Self.limit)+ resultados" : (hits.count == 1 ? "1 resultado" : "\(hits.count) resultados"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Listo") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func readingBar(_ session: Session) -> some View {
        HStack(spacing: 10) {
            Button {
                reading = nil
            } label: {
                Label("Volver", systemImage: "chevron.left")
            }
            AgentLogo(kind: session.kind, size: 16)
            Text(session.name)
                .font(.system(size: 13, weight: .semibold))
            Chip(text: "Archivada")
            Spacer()
            Button("Restaurar") {
                store.unarchive(session.id)
                sidePanel = "history"
                dismiss()
            }
            Button("Listo") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var results: some View {
        if trimmedQuery.count < 2 {
            placeholder("Escribí al menos dos letras. Se busca en lo que hablaste con Claude y Codex en todas las sesiones, también en las archivadas, sin distinguir tildes ni mayúsculas.")
        } else if hits.isEmpty && !searching {
            placeholder("Nada coincide con «\(trimmedQuery)».")
        } else {
            List(selection: $selection) {
                ForEach(groups, id: \.sessionId) { group in
                    Section {
                        ForEach(group.hits) { hit in
                            HistorySearchRow(hit: hit, query: trimmedQuery, agent: group.session?.kind ?? .claude)
                                .tag(hit.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { choose(hit) }
                                .onTapGesture { selection = hit.id }
                        }
                    } header: {
                        HistorySearchHeader(sessionId: group.sessionId)
                    }
                }
            }
            .listStyle(.inset)
            .onKeyPress(.return) {
                guard let id = selection, let hit = hits.first(where: { $0.id == id }) else { return .ignored }
                choose(hit)
                return .handled
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Datos

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Los resultados agrupados por sesión, en el orden del primero (lo más nuevo arriba).
    private var groups: [(sessionId: UUID, session: Session?, hits: [HistoryStore.SearchHit])] {
        var order: [UUID] = []
        var bySession: [UUID: [HistoryStore.SearchHit]] = [:]
        for hit in hits {
            if bySession[hit.sessionId] == nil { order.append(hit.sessionId) }
            bySession[hit.sessionId, default: []].append(hit)
        }
        return order.map { ($0, store.sessionContext($0)?.session, bySession[$0] ?? []) }
    }

    private func search() async {
        let q = trimmedQuery
        guard q.count >= 2 else {
            hits = []
            searching = false
            return
        }
        // Una pausa corta: no buscar en cada tecla.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        let ids = store.projects.flatMap { $0.branches.flatMap(\.sessions) }.filter { $0.kind.reportsConversation }.map(\.id)
        let history = store.history
        let limit = Self.limit
        let found = await Task.detached(priority: .userInitiated) { history.search(q, sessionIds: ids, limit: limit) }.value
        guard !Task.isCancelled else { return }
        hits = found
        selection = found.first?.id
        searching = false
    }

    private func choose(_ hit: HistoryStore.SearchHit) {
        guard let ctx = store.sessionContext(hit.sessionId) else { return }
        if ctx.session.isArchived {
            archivedChoice = hit
        } else {
            open(hit, restore: false)
        }
    }

    private func open(_ hit: HistoryStore.SearchHit, restore: Bool) {
        guard let ctx = store.sessionContext(hit.sessionId) else { return }
        HistoryJumpRequest.shared.pending = .init(sessionId: hit.sessionId, entryId: hit.entryId, query: trimmedQuery)
        sidePanel = "history"
        if restore {
            store.unarchive(hit.sessionId)
        } else {
            store.setExpanded(ctx.project.id, true)
            store.setExpanded(ctx.branch.id, true)
            store.select(.session(hit.sessionId))
        }
        dismiss()
    }

    private func showArchived(_ hit: HistoryStore.SearchHit) {
        guard let session = store.sessionContext(hit.sessionId)?.session else { return }
        HistoryJumpRequest.shared.pending = .init(sessionId: hit.sessionId, entryId: hit.entryId, query: trimmedQuery)
        reading = session
    }
}

private struct HistorySearchHeader: View {
    @Environment(AppStore.self) private var store
    let sessionId: UUID

    var body: some View {
        if let ctx = store.sessionContext(sessionId) {
            HStack(spacing: 6) {
                AgentLogo(kind: ctx.session.kind, size: 13)
                Text(ctx.session.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(ctx.project.isScratch ? ctx.project.name : "\(ctx.project.name) › \(ctx.branch.name)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if ctx.session.isArchived {
                    Chip(text: "Archivada", help: "Al abrirla te pregunta si querés restaurarla")
                }
            }
        } else {
            Text("Sesión eliminada")
        }
    }
}

private struct HistorySearchRow: View {
    let hit: HistoryStore.SearchHit
    let query: String
    let agent: SessionKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch hit.role {
                case .user: Text("Vos")
                case .assistant: Text(agent.defaultName)
                default: Text("Aviso")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
            Text(highlighted)
                .font(.system(size: 12.5))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(HistoryExport.dayLabel(hit.date)) · \(hit.date.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// El fragmento sin las marcas de Markdown que no se ven bien en una línea (títulos y viñetas),
    /// con negritas y `código` aplicados y la coincidencia resaltada.
    private var highlighted: AttributedString {
        let clean = hit.snippet
            .replacingOccurrences(of: #"(^|[\s…])#{1,6}\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(^|[\s…])[-*+]\s+"#, with: "$1• ", options: .regularExpression)
        var text = HistoryMarkdown.inline(clean)
        HistoryMarkdown.highlight(&text, query: query)
        return text
    }
}
