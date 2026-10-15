import AppKit
import HiveCore
import SwiftUI

/// Panel lateral con todo lo que se habló en la sesión, también lo anterior a cada /clear.
struct HistoryPanel: View {
    @Environment(AppStore.self) private var store
    let session: Session
    @State private var entries: [HistoryEntry] = []
    @State private var query = ""

    var body: some View {
        let shown = filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("Historial")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    ExternalApps.copyToPasteboard(entries.map(plainText).joined(separator: "\n\n"))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copiar todo el historial")
                .disabled(entries.isEmpty)
                Button {
                    NSWorkspace.shared.open(store.history.markdownURL(session.id))
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Abrir el archivo (es el mismo que puede leer la IA)")
                .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            TextField("Buscar en el historial", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            if entries.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text("Nada coincide con «\(query)».")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(shown) { entry in
                                HistoryRow(entry: entry, agent: session.kind).id(entry.id)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear { if query.isEmpty, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: entries.count) { if query.isEmpty, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: store.historyVersions[session.id] ?? 0) {
            let id = session.id
            let history = store.history
            entries = await Task.detached { history.load(id) }.value
        }
    }

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.role == .marker || $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var emptyText: String {
        switch session.kind {
        case .claude, .codex:
            "Todavía no hay mensajes. Lo que hables con \(session.kind.label) se guarda acá, también lo anterior a cada /clear."
        case .gemini:
            "Gemini no avisa sus mensajes a Hive, así que no hay historial acá. Todo queda en el scroll de la terminal."
        case .shell:
            "Las terminales no tienen historial de chat. Todo queda en el scroll de la terminal."
        }
    }

    private func plainText(_ entry: HistoryEntry) -> String {
        switch entry.role {
        case .user: "Vos: \(entry.text)"
        case .assistant: "\(session.kind.label): \(entry.text)"
        case .marker: "—— \(entry.text) ——"
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let agent: SessionKind
    @State private var hovering = false

    var body: some View {
        if entry.role == .marker {
            HStack(spacing: 8) {
                Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1)
                Text("\(entry.text) · \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1)
            }
            .padding(.vertical, 6)
            .help("Acá se limpió el contexto: lo de arriba ya no está en la memoria de la IA, pero sí en este historial.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if entry.role == .assistant {
                        AgentLogo(kind: agent, size: 14)
                        Text(agent.label).font(.caption.weight(.semibold))
                    } else {
                        Image(systemName: "person.fill").font(.caption)
                        Text("Vos").font(.caption.weight(.semibold))
                    }
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if hovering {
                        Button {
                            ExternalApps.copyToPasteboard(entry.text)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copiar")
                    }
                }
                .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(entry.role == .user ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
        }
    }
}
