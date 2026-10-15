import AppKit
import HiveCore
import SwiftUI

/// Lista de archivos modificados, al estilo del panel de control de código de VS Code.
struct ChangesList: View {
    @Environment(AppStore.self) private var store
    let status: GitStatus
    let directory: String
    /// Si es false y no hay nada preparado, no se repite el título «Cambios» (cuando la sección
    /// que la contiene ya se llama así).
    var showsHeaderWhenAlone = true
    @State private var showStaged = true
    @State private var showChanges = true

    var body: some View {
        let staged = status.changes.filter(\.isStaged)
        let unstaged = status.changes.filter(\.isUnstaged)
        LazyVStack(alignment: .leading, spacing: 0) {
            if !staged.isEmpty {
                ListHeader(title: "Preparados", count: staged.count, expanded: $showStaged)
                if showStaged {
                    ForEach(staged) { change in
                        ChangeRow(change: change, staged: true, directory: directory) {
                            store.openDiff(directory: directory, status: status, change: change, staged: true)
                        }
                    }
                }
            }
            let showsHeader = showsHeaderWhenAlone || !staged.isEmpty
            if showsHeader {
                ListHeader(title: "Cambios", count: unstaged.count, expanded: $showChanges)
            }
            if showChanges || !showsHeader {
                if unstaged.isEmpty {
                    Text(staged.isEmpty ? "No hay cambios en esta rama." : "No hay cambios sin preparar.")
                        .font(HiveFont.secondary)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, showsHeader ? 28 : 14)
                        .padding(.vertical, 6)
                } else {
                    ForEach(unstaged) { change in
                        ChangeRow(change: change, staged: false, directory: directory, indent: showsHeader ? 26 : 12) {
                            store.openDiff(directory: directory, status: status, change: change, staged: false)
                        }
                    }
                }
            }
        }
    }
}

private struct ListHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        DisclosureHeader(title: title, count: count, expanded: $expanded)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

private struct ChangeRow: View {
    let change: GitChange
    let staged: Bool
    let directory: String
    var indent: CGFloat = 26
    let onOpenDiff: () -> Void
    @State private var hovering = false
    @FocusState private var rowFocused: Bool
    @FocusState private var openFocused: Bool

    var body: some View {
        let badge = change.badge(staged: staged)
        // Las acciones se ven al pasar el mouse y también con el foco del teclado.
        let showsActions = hovering || rowFocused || openFocused
        HStack(spacing: 6) {
            Button(action: onOpenDiff) {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($rowFocused)
            .accessibilityLabel("\(change.fileName), \(ChangeColors.description(for: badge))")
            .accessibilityHint("Abre el diff")
            if showsActions {
                Button {
                    open()
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .focused($openFocused)
                .help("Abrir en el editor")
                .accessibilityLabel("Abrir \(change.fileName) en el editor")
            }
            Text(badge)
                .font(.system(size: 12, weight: .semibold).monospaced())
                .foregroundStyle(ChangeColors.color(for: badge))
                .frame(width: 14)
                .accessibilityHidden(true)
        }
        .font(HiveFont.body)
        .padding(.leading, indent)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(showsActions ? Color.primary.opacity(0.07) : .clear)
        .onHover { hovering = $0 }
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
        ExternalApps.openInEditor(url.path)
    }
}

/// Los colores de VS Code para cada estado de git: Dark+ en oscuro y Light+ en claro (que se
/// leen sobre blanco con contraste ≥ 4,5).
enum ChangeColors {
    static func nsColor(for badge: String) -> NSColor? {
        switch badge {
        case "M": modified
        case "A", "U", "R", "C": added
        case "D": deleted
        case "!": conflict
        default: nil
        }
    }

    static func color(for badge: String) -> Color {
        nsColor(for: badge).map { Color(nsColor: $0) } ?? .secondary
    }

    /// Para VoiceOver: qué significa cada letra.
    static func description(for badge: String) -> String {
        switch badge {
        case "M": "modificado"
        case "A": "agregado"
        case "U": "sin seguimiento"
        case "R": "renombrado"
        case "C": "copiado"
        case "D": "borrado"
        case "!": "en conflicto"
        case "T": "cambió de tipo"
        default: "cambiado"
        }
    }

    private static let modified = Theme.dynamicNSColor(light: Theme.srgb(0x895503), dark: Theme.srgb(0xE2C08D))
    private static let added = Theme.dynamicNSColor(light: Theme.srgb(0x007100), dark: Theme.srgb(0x73C991))
    private static let deleted = Theme.dynamicNSColor(light: Theme.srgb(0xAD0707), dark: Theme.srgb(0xE5664F))
    private static let conflict = Theme.dynamicNSColor(light: Theme.srgb(0xB31D28), dark: Theme.srgb(0xE4676B))
}

/// Cantidad de archivos con cambios y commits por pushear / traer, en una cápsula chica.
struct GitCounters: View {
    let status: GitStatus

    var body: some View {
        if !status.isClean {
            HStack(spacing: 5) {
                if !status.changes.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "pencil")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(status.changes.count)")
                    }
                    .foregroundStyle(ChangeColors.color(for: "M"))
                }
                if status.ahead > 0 { Text("↑\(status.ahead)") }
                if status.behind > 0 { Text("↓\(status.behind)") }
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .help(Self.description(status))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.description(status))
        }
    }

    /// «3 archivos con cambios · 1 commit sin pushear».
    static func description(_ status: GitStatus) -> String {
        var parts: [String] = []
        let n = status.changes.count
        if n > 0 { parts.append(n == 1 ? "1 archivo con cambios" : "\(n) archivos con cambios") }
        if status.ahead > 0 { parts.append(status.ahead == 1 ? "1 commit sin pushear" : "\(status.ahead) commits sin pushear") }
        if status.behind > 0 { parts.append(status.behind == 1 ? "1 commit sin traer" : "\(status.behind) commits sin traer") }
        return parts.joined(separator: " · ")
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
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(status?.branch ?? branchName)
                    .font(HiveFont.heading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status?.upstream ?? "Sin upstream")
                    .font(HiveFont.meta)
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
            .accessibilityLabel("Actualizar el estado de git")
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
                    .font(HiveFont.secondary)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Los últimos commits de una rama activa. Se vuelven a leer cuando cambia el estado de git.
struct RecentCommits: View {
    let git: GitClient
    let directory: String
    /// Cambia cuando cambia el estado de git, para volver a leer los commits.
    let refreshKey: String
    @Environment(\.hiveNow) private var fixedNow
    @State private var commits: [GitCommit] = []
    @State private var loaded = false

    /// Clave de refresco a partir del estado de git (cambia con un commit, un pull o un push).
    static func refreshKey(_ status: GitStatus?) -> String {
        guard let status else { return "-" }
        return "\(status.branch ?? "")|\(status.ahead)|\(status.behind)|\(status.changes.count)"
    }

    var body: some View {
        let now = fixedNow ?? Date()
        VStack(alignment: .leading, spacing: 0) {
            if commits.isEmpty {
                Text(loaded ? "Todavía no hay commits." : "Cargando…")
                    .font(HiveFont.secondary)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                if index > 0 { Divider().padding(.leading, 14) }
                HStack(spacing: 10) {
                    Text(commit.hash)
                        .font(HiveFont.meta.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                    Text(commit.subject)
                        .font(HiveFont.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(commit.subject)
                    Spacer(minLength: 8)
                    Text(commit.author)
                        .font(HiveFont.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(RelativeTime.string(commit.date, relativeTo: now))
                        .font(HiveFont.meta)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(directory)|\(refreshKey)") {
            let dir = directory
            let git = self.git
            commits = await Task.detached { git.recentCommits(dir, limit: 8) }.value
            loaded = true
        }
    }
}
