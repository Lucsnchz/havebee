import HiveCore
import SwiftUI

// MARK: - Esquinita con los comandos corriendo

/// Comandos del proyecto corriendo, abajo a la derecha de la ventana.
struct CommandsDock: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if !store.commandRuns.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                if store.dockExpanded, let run = store.commandRuns.first(where: { $0.id == store.dockRunId }) ?? store.commandRuns.last {
                    DockCard(run: run)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                DockChip()
            }
            .padding(14)
            .animation(.easeOut(duration: 0.18), value: store.dockExpanded)
        }
    }
}

private struct DockChip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let runs = store.commandRuns
        let running = runs.filter(\.running).count
        Button {
            store.dockExpanded.toggle()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(running > 0 ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Image(systemName: "terminal")
                Text(runs.count == 1 ? runs[0].name : (running > 0 ? "\(running) corriendo" : "\(runs.count) comandos"))
                    .lineLimit(1)
                Image(systemName: store.dockExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .help(store.dockExpanded ? "Ocultar comandos" : "Ver comandos corriendo")
    }
}

private struct DockCard: View {
    @Environment(AppStore.self) private var store
    let run: CommandRun

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.commandRuns) { item in
                            RunTab(run: item, selected: item.id == run.id)
                        }
                    }
                }
                Spacer(minLength: 8)
                Group {
                    Button { store.restartRun(run.id) } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Reiniciar")
                    if run.running {
                        Button { store.stopRun(run.id) } label: { Image(systemName: "stop.fill") }
                            .help("Detener (Ctrl+C)")
                    }
                    Button { store.closeRun(run.id) } label: { Image(systemName: "xmark") }
                        .help("Cerrar")
                    Button { store.dockExpanded = false } label: { Image(systemName: "chevron.down") }
                        .help("Ocultar")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            TerminalContainer(terminal: run.terminal)
                .frame(height: 260)
            Divider()
            HStack(spacing: 6) {
                if let project = store.project(run.projectId) {
                    ProjectTile(project: project, size: 14)
                    Text("\(project.name) › \(run.branchName)")
                }
                Text(run.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(run.running ? "Corriendo" : (run.exitCode == nil || run.exitCode == 0 ? "Terminó" : "Terminó con código \(run.exitCode!)"))
                    .foregroundStyle(run.running ? Color.green : (run.exitCode ?? 0) == 0 ? Color.secondary : Color.red)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }
}

private struct RunTab: View {
    @Environment(AppStore.self) private var store
    let run: CommandRun
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(run.running ? Color.green : ((run.exitCode ?? 0) == 0 ? Color.secondary : Color.red))
                .frame(width: 6, height: 6)
            Text(run.name)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.dockRunId = run.id }
        .help("\(run.command) · \(run.branchName)")
    }
}

// MARK: - Lista de comandos (resumen del proyecto y vista de rama)

struct CommandsSection: View {
    @Environment(AppStore.self) private var store
    let project: Project
    /// Si se pasa, los comandos corren en esta rama; si no, en la abierta o la activa.
    var branch: Branch? = nil
    /// En el resumen del proyecto se pueden agregar comandos y ver sugerencias.
    var editable = true

    var body: some View {
        let suggestions = editable ? store.commandSuggestions(for: project) : []
        VStack(alignment: .leading, spacing: 8) {
            if project.commands.isEmpty && !editable {
                EmptyView()
            }
            ForEach(project.commands) { command in
                CommandRow(project: project, command: command, branch: branch)
            }
            if editable {
                HStack(spacing: 8) {
                    Button {
                        store.commandEditor = CommandEditorTarget(projectId: project.id, commandId: nil)
                    } label: {
                        Label("Agregar comando", systemImage: "plus")
                    }
                    if !suggestions.isEmpty {
                        Text("Sugeridos:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestions, id: \.command) { suggestion in
                                    Button {
                                        store.saveCommand(projectId: project.id, commandId: nil, name: suggestion.name, command: suggestion.command)
                                    } label: {
                                        Text(suggestion.command)
                                            .font(.caption.monospaced())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.primary.opacity(0.06), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Agregar «\(suggestion.command)»")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CommandRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let command: ProjectCommand
    let branch: Branch?
    @State private var hovering = false

    var body: some View {
        let target = branch ?? store.defaultBranch(for: project)
        let running = target.flatMap { store.runningRun(commandId: command.id, branchId: $0.id) }
        HStack(spacing: 12) {
            Button {
                if let running { store.stopRun(running.id) } else { store.run(command.id, projectId: project.id, branchId: target?.id) }
            } label: {
                Image(systemName: running == nil ? "play.fill" : "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(running == nil ? Color.green : Color.red)
                    .frame(width: 28, height: 28)
                    .background((running == nil ? Color.green : Color.red).opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .help(running == nil ? "Ejecutar en \(target?.name ?? "")" : "Detener")
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.system(size: 13, weight: .medium))
                Text(command.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let running {
                Button("Ver salida") { store.showRun(running.id) }
                    .buttonStyle(.borderless)
                Text("corriendo en \(running.branchName)")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let target {
                Text("en \(target.name)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Editar…") { store.commandEditor = CommandEditorTarget(projectId: project.id, commandId: command.id) }
            Button("Eliminar") { store.deleteCommand(projectId: project.id, commandId: command.id) }
        }
    }
}

// MARK: - Editor

struct CommandEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: CommandEditorTarget
    @State private var name = ""
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.commandId == nil ? "Nuevo comando" : "Editar comando")
                .font(.headline)
            Form {
                TextField("Nombre", text: $name, prompt: Text("Servidor de desarrollo"))
                TextField("Comando", text: $command, prompt: Text("npm run dev"))
                    .font(.body.monospaced())
            }
            Text("Corre en la carpeta de la rama, con tu shell (carga tu .zshrc, nvm, etc.).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let commandId = target.commandId {
                    Button("Eliminar", role: .destructive) {
                        store.deleteCommand(projectId: target.projectId, commandId: commandId)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    store.saveCommand(projectId: target.projectId, commandId: target.commandId, name: name, command: command)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let id = target.commandId, let existing = store.project(target.projectId)?.commands.first(where: { $0.id == id }) {
                name = existing.name
                command = existing.command
            }
        }
    }
}
