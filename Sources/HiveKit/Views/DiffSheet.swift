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
    /// Lo que tocaste en la barra de conflicto y espera tu confirmación (pisar un archivo no se deshace).
    @State private var pendingChoice: ConflictChoice?
    @State private var copied = false

    /// `pendingChoice`: para mostrar la confirmación ya abierta (las capturas de los tests).
    init(target: DiffTarget, pendingChoice: ConflictChoice? = nil) {
        self.target = target
        _selected = State(initialValue: target.selected)
        _pendingChoice = State(initialValue: pendingChoice)
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
        .onChange(of: selected) { pendingChoice = nil }
        .background {
            // Flechas para pasar de archivo, Esc para cerrar.
            Group {
                Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
                // Con una confirmación abierta en la barra del conflicto, Esc la cancela (no cierra la hoja).
                Button("") {
                    if pendingChoice != nil { pendingChoice = nil } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
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

    /// Barra para resolver un conflicto sin salir de la hoja. «Usar la mía» y «Usar la de ellos» (y
    /// «Marcar resuelto» con marcadores todavía) piden confirmación en la misma barra: la hoja no
    /// puede mostrar alertas.
    private func conflictBar(_ file: DiffTarget.File) -> some View {
        let operation = store.dirStatus[target.directory]?.operation
        let done = resolved[file.change.path]
        let prompt = done == nil ? pendingChoice.flatMap { prompt(for: $0, file: file, operation: operation) } : nil
        return HStack(spacing: 8) {
            Image(systemName: done == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(done == nil ? Theme.danger : ChangeColors.color(for: "A"))
            if let prompt, let choice = pendingChoice {
                Text(prompt.message)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(prompt.message)
                Spacer(minLength: 8)
                Button("Cancelar") { pendingChoice = nil }
                Button(prompt.confirmTitle, role: .destructive) {
                    pendingChoice = nil
                    perform(choice, file: file, operation: operation)
                }
                .foregroundStyle(Theme.danger)
            } else {
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
                    Button("Usar la mía") { ask(.mine, file: file, operation: operation) }
                        .help(operation == .rebase ? "Quedarte con tu versión (en un rebase, «theirs»)" : "Quedarte con la versión de HEAD (--ours)")
                    Button("Usar la de ellos") { ask(.theirs, file: file, operation: operation) }
                        .help(operation == .rebase ? "Quedarte con la versión de la rama de destino (en un rebase, «ours»)" : "Quedarte con la versión que se está trayendo (--theirs)")
                    Button("Marcar resuelto") { ask(.markResolved, file: file, operation: operation) }
                        .help("Ya lo arreglaste a mano: git add")
                }
            }
        }
        .font(.system(size: 12))
        .disabled(resolving)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.danger.opacity(done == nil ? 0.1 : 0.03))
    }

    private func prompt(for choice: ConflictChoice, file: DiffTarget.File, operation: GitOperation?) -> ConflictPrompt? {
        ConflictPrompt.make(choice, fileName: file.change.fileName, code: file.change.code,
                            swapsOursAndTheirs: operation?.swapsOursAndTheirs == true, hasMarkers: ConflictPrompt.hasMarkers(diff))
    }

    /// Pide confirmación si hace falta; si no (marcar resuelto sin marcadores), lo hace directo.
    private func ask(_ choice: ConflictChoice, file: DiffTarget.File, operation: GitOperation?) {
        guard choice == .markResolved else {
            pendingChoice = choice
            return
        }
        // El diff que se ve puede ser de antes de que lo arreglaras en el editor (o seguir cargando):
        // se vuelve a leer antes de decidir si quedan marcadores.
        let index = selected
        resolving = true
        Task {
            let fresh = await Self.markResolvedCheck(file, in: target.directory, git: store.git)
            resolving = false
            guard selected == index else { return }
            diff = fresh.diff
            if fresh.prompt == nil {
                perform(.markResolved, file: file, operation: operation)
            } else {
                pendingChoice = .markResolved
            }
        }
    }

    /// El diff del archivo recién leído y, si todavía tiene marcadores de conflicto, la confirmación
    /// para marcarlo resuelto igual.
    static func markResolvedCheck(_ file: DiffTarget.File, in directory: String, git: GitClient) async -> (diff: FileDiff, prompt: ConflictPrompt?) {
        let diff = await Task.detached { git.diff(for: file.change, staged: file.staged, in: directory) }.value
        let prompt = ConflictPrompt.make(.markResolved, fileName: file.change.fileName, code: file.change.code,
                                         hasMarkers: ConflictPrompt.hasMarkers(diff))
        return (diff, prompt)
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

    private func perform(_ choice: ConflictChoice, file: DiffTarget.File, operation: GitOperation?) {
        let resolution = ConflictPrompt.resolution(for: choice, swapsOursAndTheirs: operation?.swapsOursAndTheirs == true)
        let message = switch choice {
        case .mine: "Te quedaste con tu versión."
        case .theirs: "Te quedaste con la versión de ellos."
        case .markResolved: "Marcado como resuelto: quedó preparado para el commit."
        }
        resolve(file, resolution: resolution, message: message)
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

    private var background: Color { DiffLineColors.background(line.kind) }
}

/// Fondo de cada línea del diff: verde lo agregado, rojo lo borrado y una franja gris en las marcas de
/// conflicto (<<<<<<<, =======, >>>>>>>), con su «!» rojo: en rojo se confundían con lo borrado.
enum DiffLineColors {
    static let markerNSColor = Theme.dynamicNSColor(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.1))

    static func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Color(red: 0.25, green: 0.75, blue: 0.45).opacity(0.16)
        case .removed: Color(red: 0.90, green: 0.30, blue: 0.30).opacity(0.16)
        case .conflictMarker: Color(nsColor: markerNSColor)
        default: .clear
        }
    }
}
