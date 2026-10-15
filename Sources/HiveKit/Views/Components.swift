import AppKit
import HiveCore
import SwiftUI

/// Indicador compacto del estado de una sesión.
struct StatusIndicator: View {
    let status: SessionStatus
    let unseen: Bool
    let kind: SessionKind

    var body: some View {
        Group {
            switch status {
            case .working:
                ProgressView().controlSize(.mini)
            case .attention:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .waiting:
                if unseen {
                    Circle().fill(.green).frame(width: 8, height: 8)
                        .shadow(color: .green.opacity(0.6), radius: 3)
                } else {
                    Circle().strokeBorder(.green.opacity(0.7), lineWidth: 1.5).frame(width: 8, height: 8)
                }
            case .idle:
                Circle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 6)
            case .exited:
                Image(systemName: "stop.circle")
                    .foregroundStyle(.tertiary)
            case .dormant:
                EmptyView()
            }
        }
        .frame(minWidth: 14)
        .help(status.label(for: kind))
    }
}

/// Resumen del estado de varias sesiones (para filas de proyecto y rama).
struct AggregateIndicator: View {
    @Environment(AppStore.self) private var store
    let sessions: [Session]

    var body: some View {
        let runtimes = sessions.compactMap { store.runtimes[$0.id] }
        if runtimes.contains(where: { $0.status == .attention }) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else if runtimes.contains(where: \.unseen) {
            Circle().fill(.green).frame(width: 8, height: 8)
        } else if runtimes.contains(where: { $0.status == .working }) {
            ProgressView().controlSize(.mini)
        }
    }
}

/// Píldora con el estado, para la barra de herramientas.
struct StatusPill: View {
    let status: SessionStatus
    let kind: SessionKind

    var body: some View {
        HStack(spacing: 6) {
            StatusIndicator(status: status, unseen: true, kind: kind)
            Text(status.label(for: kind))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}

/// Menú "Abrir en…" para la barra de herramientas.
struct OpenInMenu: View {
    let path: String

    var body: some View {
        Menu {
            OpenInItems(path: path)
        } label: {
            Label("Abrir en…", systemImage: "arrow.up.forward.app")
        }
        .help("Abrir la carpeta en otra app")
    }
}

/// Lista de archivos modificados, al estilo del panel de control de código de VS Code.
struct ChangesList: View {
    @Environment(AppStore.self) private var store
    let status: GitStatus
    let directory: String
    @State private var showStaged = true
    @State private var showChanges = true

    var body: some View {
        let staged = status.changes.filter(\.isStaged)
        let unstaged = status.changes.filter(\.isUnstaged)
        LazyVStack(alignment: .leading, spacing: 0) {
            if !staged.isEmpty {
                ChangesSectionHeader(title: "Preparados", count: staged.count, expanded: $showStaged)
                if showStaged {
                    ForEach(staged) { change in
                        ChangeRow(change: change, staged: true, directory: directory) {
                            store.openDiff(directory: directory, status: status, change: change, staged: true)
                        }
                    }
                }
            }
            ChangesSectionHeader(title: "Cambios", count: unstaged.count, expanded: $showChanges)
            if showChanges {
                if unstaged.isEmpty {
                    Text(staged.isEmpty ? "No hay cambios en esta rama." : "No hay cambios sin preparar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 6)
                } else {
                    ForEach(unstaged) { change in
                        ChangeRow(change: change, staged: false, directory: directory) {
                            store.openDiff(directory: directory, status: status, change: change, staged: false)
                        }
                    }
                }
            }
        }
    }
}

private struct ChangesSectionHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ChangeRow: View {
    let change: GitChange
    let staged: Bool
    let directory: String
    let onOpenDiff: () -> Void
    @State private var hovering = false

    var body: some View {
        let badge = change.badge(staged: staged)
        HStack(spacing: 6) {
            FileIcon(path: change.path, size: 16)
            (Text(change.fileName)
                .strikethrough(badge == "D")
             + Text(change.folder.isEmpty ? "" : "  \(change.folder)")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if hovering {
                Button {
                    open()
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Abrir en el editor")
            }
            Text(badge)
                .font(.system(size: 12, weight: .semibold).monospaced())
                .foregroundStyle(ChangeColors.color(for: badge))
                .frame(width: 14)
        }
        .font(.system(size: 13))
        .padding(.leading, 26)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(hovering ? Color.primary.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpenDiff() }
        .help("\(change.path) · clic para ver el diff")
        .contextMenu {
            Button("Ver diff") { onOpenDiff() }
            Button("Abrir en el editor") { open() }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copiar ruta") { ExternalApps.copyToPasteboard(change.path) }
        }
    }

    private var url: URL { URL(fileURLWithPath: directory).appendingPathComponent(change.path) }

    private func open() {
        if let editor = ExternalApps.editors.first {
            ExternalApps.open(url.path, with: editor)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

}

/// Los mismos colores que usa VS Code para cada estado de git.
enum ChangeColors {
    static func color(for badge: String) -> Color {
        switch badge {
        case "M": Color(red: 0.89, green: 0.75, blue: 0.55)
        case "A", "U", "R", "C": Color(red: 0.45, green: 0.79, blue: 0.57)
        case "D": Color(red: 0.78, green: 0.31, blue: 0.22)
        case "!": Color(red: 0.89, green: 0.40, blue: 0.42)
        default: .secondary
        }
    }
}

/// Rama, upstream y commits por pushear / traer.
struct UpstreamSummary: View {
    @Environment(AppStore.self) private var store
    let status: GitStatus?
    let branchName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(status?.branch ?? branchName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status?.upstream ?? "Sin upstream")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let status {
                if status.ahead > 0 { Chip(text: "↑ \(status.ahead)", help: "Commits sin pushear") }
                if status.behind > 0 { Chip(text: "↓ \(status.behind)", help: "Commits sin traer") }
            }
            Button {
                store.refreshGit()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Actualizar")
        }
    }
}

/// Panel lateral con los cambios de la rama (dentro de una sesión).
struct ChangesPanel: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch

    var body: some View {
        let status = store.gitStatus(for: branch, in: project)
        VStack(spacing: 0) {
            UpstreamSummary(status: status, branchName: branch.name)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if let status {
                ScrollView {
                    ChangesList(status: status, directory: project.directory(for: branch))
                        .padding(.vertical, 4)
                }
            } else {
                Text("Sin información de git para esta rama.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct Chip: View {
    let text: String
    var help: String = ""

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(help)
    }
}

/// Muestra la terminal (un NSView que vive en el runtime de la sesión, así el proceso
/// sigue corriendo aunque cambies de sesión).
struct TerminalContainer: NSViewRepresentable {
    let terminal: NSView?

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView()
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.show(terminal)
    }
}

final class TerminalHostView: NSView {
    private weak var current: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TerminalTheme.background.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ view: NSView?) {
        guard view !== current else { return }
        current?.removeFromSuperview()
        current = view
        guard let view else { return }
        view.removeFromSuperview()
        view.autoresizingMask = []
        view.frame = terminalFrame
        addSubview(view)
        needsLayout = true
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    // El tamaño se recalcula en cada layout. Antes dependía del autoresizing a partir del primer
    // frame: si la terminal se montaba cuando este contenedor todavía medía 0×0 (al venir desde
    // una rama), el margen daba un rectángulo inválido y la terminal quedaba en negro.
    override func layout() {
        super.layout()
        current?.frame = terminalFrame
    }

    private var terminalFrame: NSRect {
        guard bounds.width > 16, bounds.height > 12 else { return bounds }
        return bounds.insetBy(dx: 8, dy: 6)
    }
}
