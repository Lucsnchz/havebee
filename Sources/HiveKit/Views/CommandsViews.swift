import HiveCore
import SwiftUI

// MARK: - Esquinita con los comandos corriendo

/// Comandos del proyecto corriendo, abajo a la derecha (en el Resumen y en la vista de rama; en
/// las sesiones van en la barra de abajo). Cuando terminan todos, el chip se va a los 5 segundos.
struct CommandsDock: View {
    @Environment(AppStore.self) private var store
    /// Todos los comandos terminaron hace un rato: el chip se esconde hasta que corra otro.
    @State private var settled = false

    var body: some View {
        let runs = store.commandRuns
        let running = runs.filter(\.running).count
        Group {
            if !runs.isEmpty && (store.dockExpanded || !settled) {
                VStack(alignment: .trailing, spacing: 8) {
                    if store.dockExpanded, let run = runs.first(where: { $0.id == store.dockRunId }) ?? runs.last {
                        CommandRunPanel(run: run, showsTabs: true) { store.dockExpanded = false }
                            .frame(width: 600)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    DockChip()
                }
                .padding(14)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.dockExpanded)
        .animation(.easeOut(duration: 0.25), value: settled)
        .task(id: running == 0 && !runs.isEmpty) {
            guard running == 0, !runs.isEmpty else {
                settled = false
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { settled = true }
        }
    }
}

private struct DockChip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let runs = store.commandRuns
        let running = runs.filter(\.running).count
        let title = runs.count == 1 ? runs[0].name : (running > 0 ? "\(running) corriendo" : "\(runs.count) comandos")
        Button {
            store.dockExpanded.toggle()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(running > 0 ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Image(systemName: "terminal")
                Text(title)
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
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(store.dockExpanded ? "Ocultar comandos" : "Ver comandos corriendo")
        .accessibilityLabel(store.dockExpanded ? "Ocultar comandos: \(title)" : "Ver comandos: \(title)")
    }
}

/// La salida de un comando con sus acciones. Se usa en la esquinita y en el popover de la
/// barra de la sesión.
struct CommandRunPanel: View {
    @Environment(AppStore.self) private var store
    let run: CommandRun
    /// En la esquinita: pestañas para cambiar entre los comandos corriendo.
    var showsTabs = false
    /// Si se pasa, muestra el botón para ocultar el panel.
    var onHide: (() -> Void)? = nil
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if showsTabs {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(store.commandRuns) { item in
                                RunTab(run: item, selected: item.id == run.id)
                            }
                        }
                    }
                } else {
                    CommandRunDot(run: run)
                    Text(run.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            TerminalContainer(terminal: run.terminal)
                .frame(height: 260)
            Divider()
            footer
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                ExternalApps.copyToPasteboard(run.terminal?.fullText() ?? "")
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .help(copied ? "Copiado" : "Copiar salida")
            .accessibilityLabel("Copiar salida")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
            Button { run.terminal?.clearTerminal(nil) } label: { Image(systemName: "eraser") }
                .help("Limpiar")
                .accessibilityLabel("Limpiar la salida")
            Button { store.restartRun(run.id) } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Reiniciar")
                .accessibilityLabel("Reiniciar \(run.name)")
            if run.running {
                Button { store.stopRun(run.id) } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .help("Detener (Ctrl+C)")
                .accessibilityLabel("Detener \(run.name)")
            }
            Button { store.closeRun(run.id) } label: { Image(systemName: "xmark") }
                .help("Cerrar")
                .accessibilityLabel("Cerrar \(run.name)")
            if let onHide {
                Button(action: onHide) { Image(systemName: "chevron.down") }
                    .help("Ocultar")
                    .accessibilityLabel("Ocultar comandos")
            }
        }
        .buttonStyle(.borderless)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let project = store.project(run.projectId) {
                ProjectTile(project: project, size: 14)
                Text(project.isScratch ? project.name : "\(project.name) › \(run.branchName)")
                    .lineLimit(1)
            }
            Text(run.command)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(CommandRunDot.label(run))
                .foregroundStyle(CommandRunDot.color(run))
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Punto de color con el estado de un comando: verde si corre, gris si terminó bien, rojo si falló.
struct CommandRunDot: View {
    let run: CommandRun
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Self.color(run))
            .frame(width: size, height: size)
    }

    static func color(_ run: CommandRun) -> Color {
        run.running ? .green : ((run.exitCode ?? 0) == 0 ? .secondary : .red)
    }

    static func label(_ run: CommandRun) -> String {
        if run.running { return "Corriendo" }
        guard let code = run.exitCode, code != 0 else { return "Terminó" }
        return "Terminó con código \(code)"
    }
}

private struct RunTab: View {
    @Environment(AppStore.self) private var store
    let run: CommandRun
    let selected: Bool

    var body: some View {
        Button {
            store.dockRunId = run.id
        } label: {
            HStack(spacing: 6) {
                CommandRunDot(run: run, size: 6)
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
        }
        .buttonStyle(.plain)
        .help("\(run.command) · \(run.branchName)")
        .accessibilityLabel("\(run.name), \(run.branchName), \(CommandRunDot.label(run))")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    /// El botón «Agregar comando» (el resumen lo puede poner en el encabezado de la sección).
    var showsAddButton = true
    @State private var suggestions: [CommandSuggestions.Suggestion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(project.commands) { command in
                CommandRow(project: project, command: command, branch: branch)
            }
            if editable && (showsAddButton || !suggestions.isEmpty) {
                HStack(spacing: 8) {
                    if showsAddButton {
                        Button {
                            store.commandEditor = CommandEditorTarget(projectId: project.id, commandId: nil)
                        } label: {
                            Label("Agregar comando", systemImage: "plus")
                        }
                    }
                    if !suggestions.isEmpty {
                        Text("Sugeridos:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, showsAddButton ? 6 : 0)
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
        // Las sugerencias leen package.json y composer.json: una vez por cambio, no en cada dibujo.
        .task(id: SuggestionsKey(path: project.path, commands: project.commands.map(\.command), editable: editable)) {
            suggestions = editable ? store.commandSuggestions(for: project) : []
        }
    }

    private struct SuggestionsKey: Equatable {
        let path: String
        let commands: [String]
        let editable: Bool
    }
}

private struct CommandRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let command: ProjectCommand
    let branch: Branch?

    var body: some View {
        let target = branch ?? store.defaultBranch(for: project)
        let running = target.flatMap { store.runningRun(commandId: command.id, branchId: $0.id) }
        let lastRun = target.flatMap { target in store.commandRuns.last { $0.commandId == command.id && $0.branchId == target.id } }
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
            .accessibilityLabel(running == nil ? "Ejecutar \(command.name)" : "Detener \(command.name)")
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
            if let lastRun {
                Button("Ver salida") { store.showRun(lastRun.id) }
                    .buttonStyle(.borderless)
            }
            if let running {
                Text("corriendo en \(running.branchName)")
                    .font(.caption)
                    .foregroundStyle(Theme.pending)
            } else if let target {
                Text("en \(target.name)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .hiveCard(interactive: true, radius: HiveCard.rowRadius)
        .contextMenu {
            Button("Editar…") { store.commandEditor = CommandEditorTarget(projectId: project.id, commandId: command.id) }
            Button("Eliminar", role: .destructive) { store.deleteCommand(projectId: project.id, commandId: command.id) }
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
                LabeledContent("Comando") {
                    TextField("Comando", text: $command, prompt: Text("npm run dev"))
                        .labelsHidden()
                        .font(.body.monospaced())
                }
            }
            Text("Corre en la carpeta de la rama, con tu shell (carga tu .zshrc, nvm, etc.).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let commandId = target.commandId {
                    Button(role: .destructive) {
                        store.deleteCommand(projectId: target.projectId, commandId: commandId)
                        dismiss()
                    } label: {
                        Text("Eliminar")
                            .foregroundStyle(.red)
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
