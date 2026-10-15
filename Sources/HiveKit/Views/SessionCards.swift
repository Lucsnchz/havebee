import HiveCore
import SwiftUI

/// Tarjeta de una sesión: estado, hace cuánto se usó y lo último que respondió el agente.
struct SessionCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.hiveNow) private var fixedNow
    let project: Project
    let branch: Branch
    let session: Session

    var body: some View {
        let rt = store.runtimes[session.id]
        let status = rt?.status ?? .dormant
        let unseen = rt?.unseen ?? false
        let ring = Activity.Ring.of(status: status, unseen: unseen)
        Button {
            store.select(.session(session.id))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AgentLogo(kind: session.kind, size: 18)
                    Text(session.name)
                        .font(HiveFont.heading)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    HStack(spacing: 5) {
                        StatusIndicator(status: status, unseen: unseen, kind: session.kind)
                        Text(status.label(for: session.kind))
                            .font(HiveFont.meta.weight(.medium))
                            .foregroundStyle(status.tint(unseen: unseen))
                    }
                }
                summaryView(Self.summary(session: session, branchName: branch.name, title: rt?.title, notice: rt?.notice))
                footer(status: status, rt: rt)
                    .font(HiveFont.meta)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .hiveCard(interactive: true, border: borderColor(ring))
        }
        .buttonStyle(.plain)
        .contextMenu { SessionMenu(project: project, branch: branch, session: session) }
        .accessibilityLabel(accessibilityText(status: status, unseen: unseen))
        .accessibilityHint("Abre la sesión")
    }

    /// Abajo: hace cuánto que trabaja, o cuándo se usó por última vez.
    @ViewBuilder
    private func footer(status: SessionStatus, rt: SessionRuntime?) -> some View {
        if status == .working, let since = rt?.workingSince {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Trabajando · \(RelativeTime.elapsed((fixedNow ?? context.date).timeIntervalSince(since)))")
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
        } else if let date = session.lastActivityAt ?? session.lastLaunchedAt {
            Text(RelativeTime.string(date, relativeTo: fixedNow ?? Date()))
                .foregroundStyle(.tertiary)
        } else {
            Text("Sin usar todavía")
                .foregroundStyle(.tertiary)
        }
    }

    /// Naranja si pide permiso, verde si te espera y no la viste; si no, el borde neutro.
    private func borderColor(_ ring: Activity.Ring) -> Color? {
        switch ring {
        case .attention: Theme.attention.opacity(0.75)
        case .pending: Theme.pending.opacity(0.6)
        default: nil
        }
    }

    /// Debajo del nombre: lo que pide el agente (en naranja, mientras espera tu permiso) o lo último que respondió.
    @ViewBuilder
    private func summaryView(_ summary: Summary) -> some View {
        Group {
            if summary.isNotice {
                Text("\(Image(systemName: "hand.raised.fill")) \(summary.text)")
                    .foregroundStyle(Theme.attention)
                    .accessibilityLabel("Necesita permiso: \(summary.text)")
            } else {
                Text(summary.text)
                    .foregroundStyle(.secondary)
            }
        }
        .font(HiveFont.secondary)
        .lineLimit(2, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// El texto de la tarjeta y si es el pedido de permiso.
    struct Summary: Equatable {
        let text: String
        let isNotice: Bool
    }

    /// Mientras pide permiso, el pedido le gana al último mensaje; si no, lo último que respondió el
    /// agente, el título de la terminal o un texto de relleno.
    static func summary(session: Session, branchName: String, title: String?, notice: String?) -> Summary {
        if let notice = notice?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty {
            return Summary(text: notice, isNotice: true)
        }
        if let message = session.lastMessage, !message.isEmpty { return Summary(text: message, isNotice: false) }
        let title = (title ?? "").trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return Summary(text: title, isNotice: false) }
        return Summary(text: session.kind.isAgent ? "Todavía sin respuestas." : "Terminal en \(branchName).", isNotice: false)
    }

    private func accessibilityText(status: SessionStatus, unseen: Bool) -> String {
        "\(session.name), \(session.kind.label), \(StatusIndicator.accessibilityText(status: status, unseen: unseen, kind: session.kind))"
    }
}

/// Tarjeta grande para crear una sesión (es el estado vacío de una rama sin sesiones).
struct NewSessionCard: View {
    @Environment(AppStore.self) private var store
    let kind: SessionKind
    let action: () -> Void
    @State private var showsInstallHint = false

    var body: some View {
        let availability = AgentAvailability.shared(for: store)
        let installed = availability.isInstalled(kind)
        Button {
            if installed {
                action()
            } else {
                Task {
                    if await availability.recheck(kind) { action() } else { showsInstallHint = true }
                }
            }
        } label: {
            VStack(spacing: 6) {
                AgentLogo(kind: kind, size: 26)
                    .opacity(installed ? 1 : 0.5)
                Text(kind.label)
                    .font(HiveFont.body.weight(.medium))
                    .lineLimit(1)
                    .opacity(installed ? 1 : 0.5)
                // Abajo y no en una esquina: con la ventana angosta, la esquina tapaba el logo.
                // Las tarjetas igualan su alto en la fila (ver BranchDetailView).
                if !installed {
                    Chip(text: "No instalado")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity)
            .padding(.vertical, 14)
            .hiveCard(interactive: true)
        }
        .buttonStyle(.plain)
        .help(installed ? "Nueva sesión de \(kind.label)" : "\(kind.label) no está instalado: tocá para ver cómo instalarlo")
        .accessibilityLabel(installed ? "Nueva sesión de \(kind.label)" : "\(kind.label), no instalado")
        .popover(isPresented: $showsInstallHint, arrowEdge: .bottom) { InstallHintPopover(kind: kind) }
    }
}

/// Píldora chica para crear una sesión, en el encabezado de «Sesiones».
struct NewSessionPill: View {
    @Environment(AppStore.self) private var store
    let kind: SessionKind
    let branchId: UUID
    @State private var hovering = false
    @State private var showsInstallHint = false

    var body: some View {
        let availability = AgentAvailability.shared(for: store)
        let installed = availability.isInstalled(kind)
        Button {
            if installed {
                store.requestNewSession(branchId: branchId, kind: kind)
            } else {
                Task {
                    if await availability.recheck(kind) {
                        store.requestNewSession(branchId: branchId, kind: kind)
                    } else {
                        showsInstallHint = true
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                AgentLogo(kind: kind, size: 14)
                Text(kind.defaultName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .opacity(installed ? 1 : 0.5)
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .frame(height: 24)
            .background(Color.primary.opacity(hovering ? 0.09 : 0.05), in: Capsule())
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(installed ? "Nueva sesión de \(kind.label)" : "\(kind.label) no está instalado")
        .accessibilityLabel(installed ? "Nueva sesión de \(kind.label)" : "\(kind.label), no instalado")
        .popover(isPresented: $showsInstallHint, arrowEdge: .bottom) { InstallHintPopover(kind: kind) }
    }
}

/// Sesiones archivadas de la rama: se puede leer su historial sin lanzarlas, restaurarlas (con
/// su conversación) o eliminarlas.
struct ArchivedSessions: View {
    @Environment(AppStore.self) private var store
    @Environment(\.hiveNow) private var fixedNow
    let sessions: [Session]
    @State private var expanded = false
    @State private var historyFor: Session?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureHeader(title: "Archivadas", count: sessions.count, expanded: $expanded, fillsWidth: false)
            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().padding(.leading, 40) }
                        row(session)
                    }
                }
                .hiveCard()
            }
        }
        .sheet(item: $historyFor) { session in
            ArchivedHistorySheet(session: session)
                .environment(store)
        }
    }

    private func row(_ session: Session) -> some View {
        HStack(spacing: 10) {
            AgentLogo(kind: session.kind, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(HiveFont.body.weight(.medium))
                Text(session.lastMessage ?? "Sin respuestas guardadas.")
                    .font(HiveFont.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let date = session.archivedAt {
                Text("archivada \(RelativeTime.string(date, relativeTo: fixedNow ?? Date()))")
                    .font(HiveFont.meta)
                    .foregroundStyle(.tertiary)
            }
            Button("Ver historial") { historyFor = session }
                .help("Leer la conversación sin abrir la sesión")
            Button("Restaurar") { store.unarchive(session.id) }
            Button {
                store.requestRemoval(.session(session.id))
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Eliminar")
            .accessibilityLabel("Eliminar \(session.name)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Historial de una sesión archivada, en una hoja (no lanza el agente).
private struct ArchivedHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: Session

    var body: some View {
        VStack(spacing: 0) {
            HistoryPanel(session: session)
            Divider()
            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
    }
}
