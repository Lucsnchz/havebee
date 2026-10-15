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
        .frame(width: 1060, height: 680)
        .task(id: selected) { await load() }
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(target.files.enumerated()), id: \.offset) { index, file in
                        if index == 0 || target.files[index - 1].staged != file.staged {
                            Text(file.staged ? "PREPARADOS" : "CAMBIOS")
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
                        .background(index == selected ? Color.accentColor.opacity(0.22) : .clear)
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

    private func header(_ file: DiffTarget.File) -> some View {
        let badge = file.change.badge(staged: file.staged)
        return HStack(spacing: 8) {
            FileIcon(path: file.change.path, size: 18)
            Text(file.change.path)
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
                let added = diff.lines.filter { $0.kind == .added }.count
                let removed = diff.lines.filter { $0.kind == .removed }.count
                Text("+\(added)").foregroundStyle(ChangeColors.color(for: "A"))
                Text("−\(removed)").foregroundStyle(ChangeColors.color(for: "D"))
            }
            Button("Abrir en editor") { openInEditor(file) }
            Button("Cerrar") { dismiss() }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if let diff {
            if let message = diff.message {
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

    private func openInEditor(_ file: DiffTarget.File) {
        let path = (target.directory as NSString).appendingPathComponent(file.change.path)
        ExternalApps.openInEditor(path)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        if line.kind == .hunk {
            Text(line.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(red: 0.45, green: 0.62, blue: 0.95))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.45, green: 0.62, blue: 0.95).opacity(0.1))
        } else {
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: 46, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: 46, alignment: .trailing)
                    .foregroundStyle(.tertiary)
                Text(prefix)
                    .frame(width: 22)
                    .foregroundStyle(prefixColor)
                Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                    .foregroundStyle(line.kind == .note ? Color.secondary : Color.primary)
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
        default: ""
        }
    }

    private var prefixColor: Color {
        line.kind == .added ? ChangeColors.color(for: "A") : ChangeColors.color(for: "D")
    }

    private var background: Color {
        switch line.kind {
        case .added: Color(red: 0.25, green: 0.75, blue: 0.45).opacity(0.16)
        case .removed: Color(red: 0.90, green: 0.30, blue: 0.30).opacity(0.16)
        default: .clear
        }
    }
}
