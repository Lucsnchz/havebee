import AppKit
import HiveCore
import SwiftUI

/// Visor de diffs: archivos modificados a la izquierda, el diff del elegido a la derecha.
struct DiffSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: DiffTarget
    @State private var selected: Int
    @State private var diff: FileDiff?
    /// Conflictos que resolviste en esta hoja (ruta → cómo), para no volver a ofrecerlo.
    @State private var resolved: [String: String] = [:]
    @State private var resolving = false
    /// Error al resolver: se muestra en la barra, porque una alerta no aparece encima de esta hoja.
    @State private var resolveError: String?
    @State private var copied = false

    init(target: DiffTarget) {
        self.target = target
        _selected = State(initialValue: target.selected)
    }

    var body: some View {
        let file = target.files.indices.contains(selected) ? target.files[selected] : nil
        HStack(spacing: 0) {
            fileList
                .frame(width: 260)
                .background(Color.primary.opacity(0.03))
            Divider()
            VStack(spacing: 0) {
                if let file { header(file) }
                Divider()
                content
            }
        }
        .frame(minWidth: 800, idealWidth: 1060, maxWidth: .infinity, minHeight: 500, idealHeight: 680, maxHeight: .infinity)
        .task(id: selected) {
            resolveError = nil
            await load()
        }
        .background {
            // Flechas para pasar de archivo, Esc para cerrar.
            Group {
                Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let hasStaged = target.files.contains(where: \.staged)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(target.files.enumerated()), id: \.offset) { index, file in
                        if index == 0 || target.files[index - 1].staged != file.staged {
                            Text(Self.sectionTitle(staged: file.staged, hasStaged: hasStaged))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, index == 0 ? 10 : 14)
                                .padding(.bottom, 4)
                        }
                        let badge = file.change.badge(staged: file.staged)
                        HStack(spacing: 6) {
                            FileIcon(path: file.change.path, size: 15)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(file.change.fileName)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                if !file.change.folder.isEmpty {
                                    Text(file.change.folder)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(badge)
                                .font(.system(size: 11.5, weight: .semibold).monospaced())
                                .foregroundStyle(ChangeColors.color(for: badge))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(index == selected ? Theme.accentFill.opacity(0.22) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = index }
                        .id(index)
                    }
                }
                .padding(.bottom, 10)
            }
            .onChange(of: selected) { _, value in proxy.scrollTo(value) }
        }
    }

    /// Título de cada grupo de la lista, con los mismos nombres que el panel de cambios: «PREPARADOS» y
    /// «SIN PREPARAR», o «CAMBIOS» si no hay nada preparado.
    static func sectionTitle(staged: Bool, hasStaged: Bool) -> String {
        (staged ? "Preparados" : ChangesList.unstagedTitle(hasStaged: hasStaged)).uppercased()
    }

    private func header(_ file: DiffTarget.File) -> some View {
        let badge = file.change.badge(staged: file.staged)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                FileIcon(path: file.change.path, size: 18)
                Group {
                    if let original = file.change.originalPath {
                        Text(original).foregroundStyle(.secondary) + Text("  →  ").foregroundStyle(.tertiary) + Text(file.change.path)
                    } else {
                        Text(file.change.path)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                Text(badge)
                    .font(.system(size: 12, weight: .semibold).monospaced())
                    .foregroundStyle(ChangeColors.color(for: badge))
                if file.staged { Chip(text: "Preparado") }
                Spacer()
                if let diff, !diff.lines.isEmpty {
                    Text("+\(diff.addedCount)").foregroundStyle(ChangeColors.color(for: "A"))
                    Text("−\(diff.removedCount)").foregroundStyle(ChangeColors.color(for: "D"))
                }
                Button(copied ? "Copiado" : "Copiar diff") { copyDiff(file) }
                    .disabled(diff?.raw.isEmpty ?? true)
                    .help("Copiar el diff de este archivo, por ejemplo para pegárselo a la IA")
                Button("Abrir en editor") { openInEditor(file) }
                Button("Cerrar") { dismiss() }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if file.change.isConflict {
                conflictBar(file)
            }
        }
    }

    /// Barra para resolver un conflicto sin salir de la hoja.
    private func conflictBar(_ file: DiffTarget.File) -> some View {
        let operation = store.dirStatus[target.directory]?.operation
        let done = resolved[file.change.path]
        return HStack(spacing: 8) {
            Image(systemName: done == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(done == nil ? Theme.danger : ChangeColors.color(for: "A"))
            VStack(alignment: .leading, spacing: 1) {
                Text(done ?? "Archivo en conflicto" + (operation.map { " · \($0.label)" } ?? ""))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if done == nil, let resolveError {
                    Text(resolveError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(resolveError)
                }
            }
            Spacer()
            if done == nil {
                if resolving { ProgressView().controlSize(.small) }
                Button("Usar la mía") { resolve(file, mine: true, operation: operation) }
                    .help(operation == .rebase ? "Quedarte con tu versión (en un rebase, «theirs»)" : "Quedarte con la versión de HEAD (--ours)")
                Button("Usar la de ellos") { resolve(file, mine: false, operation: operation) }
                    .help(operation == .rebase ? "Quedarte con la versión de la rama de destino (en un rebase, «ours»)" : "Quedarte con la versión que se está trayendo (--theirs)")
                Button("Marcar resuelto") { resolve(file, resolution: .markResolved, message: "Marcado como resuelto: quedó preparado para el commit.") }
                    .help("Ya lo arreglaste a mano: git add")
            }
        }
        .font(.system(size: 12))
        .disabled(resolving)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.danger.opacity(done == nil ? 0.1 : 0.03))
    }

    @ViewBuilder private var content: some View {
        if let diff {
            if let file = target.files.indices.contains(selected) ? target.files[selected] : nil,
               let done = resolved[file.change.path], diff.lines.isEmpty {
                placeholder(done)
            } else if let message = diff.message {
                placeholder(message)
            } else if diff.isBinary && diff.lines.isEmpty {
                placeholder("Archivo binario: no se puede mostrar el diff.")
            } else if diff.lines.isEmpty {
                placeholder("Sin diferencias para mostrar.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines) { DiffLineRow(line: $0) }
                        if diff.truncated {
                            Text("El diff es muy largo: se muestran las primeras \(GitParsing.maxDiffLines) líneas.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard target.files.indices.contains(selected) else { return }
        diff = nil
        let file = target.files[selected]
        let dir = target.directory
        let git = store.git
        diff = await Task.detached { git.diff(for: file.change, staged: file.staged, in: dir) }.value
    }

    private func move(_ delta: Int) {
        let next = selected + delta
        if target.files.indices.contains(next) { selected = next }
    }

    private func resolve(_ file: DiffTarget.File, mine: Bool, operation: GitOperation?) {
        // En un rebase, «ours» es la rama de destino y «theirs» tu commit.
        let swapped = operation?.swapsOursAndTheirs == true
        let resolution: ConflictResolution = mine != swapped ? .ours : .theirs
        resolve(file, resolution: resolution, message: mine ? "Te quedaste con tu versión." : "Te quedaste con la versión de ellos.")
    }

    private func resolve(_ file: DiffTarget.File, resolution: ConflictResolution, message: String) {
        let git = store.git
        let dir = target.directory
        let path = file.change.path
        resolving = true
        resolveError = nil
        Task {
            let r = await Task.detached { git.resolveConflict(path: path, using: resolution, in: dir) }.value
            resolving = false
            if r.ok {
                resolved[path] = message
            } else {
                let detail = r.errorMessage.isEmpty ? "git terminó con el código \(r.status)." : r.errorMessage
                resolveError = "No pude resolverlo: \(detail)"
            }
            store.refreshGit()
            await load()
        }
    }

    private func copyDiff(_ file: DiffTarget.File) {
        guard let diff, !diff.raw.isEmpty else { return }
        ExternalApps.copyToPasteboard(diff.raw)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func openInEditor(_ file: DiffTarget.File) {
        let path = (target.directory as NSString).appendingPathComponent(file.change.path)
        ExternalApps.openInEditor(path)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    /// Azul de los encabezados de cada parte, legible en claro y en oscuro.
    static let hunkColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.70, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.16, green: 0.36, blue: 0.78, alpha: 1)
    })

    var body: some View {
        if line.kind == .hunk {
            Text(line.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Self.hunkColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.hunkColor.opacity(0.1))
        } else {
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: 46, alignment: .trailing)
                    .foregroundStyle(Theme.secondaryText)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: 46, alignment: .trailing)
                    .foregroundStyle(Theme.secondaryText)
                Text(prefix)
                    .frame(width: 22)
                    .foregroundStyle(prefixColor)
                Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                    .foregroundStyle(line.kind == .note ? Color.secondary : Color.primary)
                    .fontWeight(line.kind == .conflictMarker ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.vertical, 1)
            .background(background)
        }
    }

    private var prefix: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .conflictMarker: "!"
        default: ""
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .added: ChangeColors.color(for: "A")
        case .conflictMarker: ChangeColors.color(for: "!")
        default: ChangeColors.color(for: "D")
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Color(red: 0.25, green: 0.75, blue: 0.45).opacity(0.16)
        case .removed: Color(red: 0.90, green: 0.30, blue: 0.30).opacity(0.16)
        case .conflictMarker: ChangeColors.color(for: "!").opacity(0.2)
        default: .clear
        }
    }
}
