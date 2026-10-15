import AppKit
import HiveCore
import SwiftUI

/// MCP del proyecto (`.mcp.json`), sugerencias por stack y los globales de cada agente.
/// Todo lo que viene del disco se lee en `.task`, fuera del hilo principal; `body` solo dibuja.
struct MCPSection: View {
    let project: Project
    /// En el resumen del proyecto el «Agregar» puede ir en el título de la sección.
    var showsAddButton: Bool

    init(project: Project, showsAddButton: Bool = true) {
        self.project = project
        self.showsAddButton = showsAddButton
    }

    var body: some View {
        // El resumen reutiliza la vista al pasar de un proyecto a otro: con `.id` cada proyecto arranca
        // con su propio estado y no se ven los MCP (ni los globales) del proyecto anterior.
        MCPSectionContent(project: project, showsAddButton: showsAddButton)
            .id(project.id)
    }
}

private struct MCPSectionContent: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let showsAddButton: Bool
    @State private var data: MCPSectionData?
    /// Sube al volver a la app, por si el `.mcp.json` cambió por fuera (`claude mcp add`, el editor).
    @State private var reloadToken = 0
    /// Si el usuario abrió o cerró los sugeridos: "" (todavía no eligió), "open" o "closed".
    @AppStorage private var suggestionsState: String

    init(project: Project, showsAddButton: Bool) {
        self.project = project
        self.showsAddButton = showsAddButton
        _suggestionsState = AppStorage(wrappedValue: "", "mcpSuggestions-\(project.id.uuidString)")
    }

    private var servers: [MCPServer] { (try? data?.servers.get()) ?? [] }
    private var loadError: MCPConfigError? {
        if case .failure(let error)? = data?.servers { return error }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let loadError {
                MCPInvalidFileNotice(error: loadError)
            } else if data != nil && servers.isEmpty {
                Text("Este proyecto no tiene MCP. Se guardan en .mcp.json del repo: Claude los lee directo y Hive se los pasa a Codex y Gemini.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(servers) { server in
                MCPRow(project: project, server: server, brokenPath: data?.brokenPaths[server.name])
            }
            if showsAddButton || data?.fileExists == true {
                HStack(spacing: 8) {
                    if showsAddButton {
                        Button {
                            store.mcpEditor = MCPEditorTarget(projectId: project.id, serverName: nil)
                        } label: {
                            Label("Agregar MCP", systemImage: "plus")
                        }
                        .disabled(data == nil || loadError != nil)
                        .help(loadError == nil ? "Agregar un MCP a .mcp.json" : "Primero corregí el error de .mcp.json")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([MCPConfig.url(in: project.path)])
                    } label: {
                        Label(".mcp.json", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderless)
                    .disabled(data?.fileExists != true)
                    .help("Mostrar .mcp.json en el Finder")
                }
            }
            if let suggestions = data?.suggestions, !suggestions.isEmpty, loadError == nil {
                DisclosureGroup(isExpanded: suggestionsExpanded) {
                    MCPChipFlow(spacing: 6) {
                        ForEach(suggestions) { item in
                            MCPSuggestionChip(item: item) {
                                store.saveMCP(MCPServer(name: item.name, config: item.config), replacing: nil, projectId: project.id)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Sugeridos (\(suggestions.count))")
                }
                .disclosureGroupStyle(MCPDisclosureStyle())
                .padding(.top, 4)
            }
            GlobalMCPs(project: project)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(project.path)-\(store.mcpVersion)-\(reloadToken)") {
            let path = project.path
            let home = store.environment.home
            let scanned = await Task.detached(priority: .userInitiated) { MCPSectionData.scan(projectPath: path, home: home) }.value
            // Si mientras leíamos cambió el archivo, ya hay otra lectura en camino: esta quedó vieja.
            guard !Task.isCancelled else { return }
            data = scanned
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadToken += 1
        }
    }

    /// Cerrados si el proyecto ya tiene algún MCP, salvo que el usuario los haya abierto.
    private var suggestionsExpanded: Binding<Bool> {
        Binding(
            get: { suggestionsState.isEmpty ? servers.isEmpty : suggestionsState == "open" },
            set: { suggestionsState = $0 ? "open" : "closed" })
    }
}

/// Lo que muestra la sección, leído de una vez fuera del hilo principal.
struct MCPSectionData: Sendable {
    var servers: Result<[MCPServer], MCPConfigError>
    var fileExists: Bool
    var suggestions: [MCPCatalog.Item]
    /// Rutas de comandos que no existen en esta Mac, por nombre de servidor.
    var brokenPaths: [String: String]

    static func scan(projectPath: String, home: URL) -> MCPSectionData {
        let file = MCPConfig.url(in: projectPath)
        let result = MCPConfig.loadResult(file)
        let servers = (try? result.get()) ?? []
        var broken: [String: String] = [:]
        for server in servers {
            if let path = server.brokenPath { broken[server.name] = path }
        }
        // Con el archivo roto no sugerimos nada: agregar fallaría igual.
        let suggestions = (try? result.get()) == nil ? [] : MCPCatalog.suggestions(projectPath: projectPath, home: home, existing: servers)
        return MCPSectionData(servers: result, fileExists: FileManager.default.fileExists(atPath: file.path),
                              suggestions: suggestions, brokenPaths: broken)
    }
}

/// Aviso cuando el `.mcp.json` no se puede leer: Hive no lo toca hasta que se corrija.
private struct MCPInvalidFileNotice: View {
    let error: MCPConfigError

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Theme.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(".mcp.json tiene un error de sintaxis")
                    .font(.system(size: 13, weight: .semibold))
                Text("Corregilo y Hive lo vuelve a leer. Mientras tanto no se agregan ni se quitan MCP desde acá, así no se pierde ninguno.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Abrir") {
                let url = URL(fileURLWithPath: error.path)
                if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .help(error.path)
        }
        .padding(12)
        .background(Theme.attention.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.attention.opacity(0.3)))
    }
}

private struct MCPRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let server: MCPServer
    let brokenPath: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.isRemote ? "globe" : "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 13, weight: .medium))
                Text(server.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let brokenPath {
                    Label("La ruta no existe en esta Mac: \(brokenPath)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.attention)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Chip(text: server.isRemote ? "remoto" : "local",
                 help: server.isRemote
                    ? "Se conecta a una URL. Lo usan Claude, Codex y Gemini."
                    : "Corre un comando en tu Mac. Lo usan Claude, Codex y Gemini.")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .hiveCard(interactive: true, radius: HiveCard.rowRadius)
        .onTapGesture(count: 2) { store.mcpEditor = MCPEditorTarget(projectId: project.id, serverName: server.name) }
        .contextMenu {
            Button("Editar…") { store.mcpEditor = MCPEditorTarget(projectId: project.id, serverName: server.name) }
            Button("Quitar", role: .destructive) { store.removeMCP(server.name, projectId: project.id) }
        }
    }
}

/// Un MCP sugerido en una línea: el nombre con un «+»; la descripción va en la ayuda.
private struct MCPSuggestionChip: View {
    let item: MCPCatalog.Item
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: add) {
            Label(item.name, systemImage: "plus")
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(hovering ? 0.1 : 0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(item.detail)\nClic para agregarlo a .mcp.json.")
    }
}

/// Acomoda los chips en filas, pasando a la siguiente cuando no entran.
private struct MCPChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Encabezado plegable chico (chevron + título en gris), con el contenido alineado al título y sin sangría.
private struct MCPDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

/// Los MCP que cada agente tiene por fuera del proyecto. Se leen la primera vez que se abren.
private struct GlobalMCPs: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var expanded = false
    @State private var groups: [MCPConfig.GlobalGroup]?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let groups {
                    if groups.isEmpty {
                        Text("No hay MCP globales configurados.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.title).font(.caption.weight(.semibold))
                                ForEach(group.servers, id: \.name) { server in
                                    HStack(spacing: 6) {
                                        Text(server.name).font(.caption)
                                        Text(server.summary)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        Text("Se configuran con cada agente (por ejemplo `claude mcp add` o `codex mcp add`). Hive solo los muestra.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("MCP globales de cada agente")
        }
        .disclosureGroupStyle(MCPDisclosureStyle())
        .task(id: expanded) {
            guard expanded, groups == nil else { return }
            let path = project.path
            let home = store.environment.home
            let codexHome = store.environment.agents.codexHome
            let loaded = await Task.detached(priority: .userInitiated) {
                MCPConfig.globals(projectPath: path, home: home, codexHome: codexHome)
            }.value
            guard !Task.isCancelled else { return } // se cerró antes de terminar: se lee al volver a abrir
            groups = loaded
        }
    }
}

/// Editor de un MCP del proyecto. La lógica (qué se guarda y qué se conserva) es `MCPServerForm`.
struct MCPEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: MCPEditorTarget

    @State private var form = MCPServerForm()
    /// El servidor tal como estaba en el archivo (nil si es nuevo).
    @State private var original: MCPServer?
    /// Los nombres que ya usa el archivo, para no pisar otro servidor.
    @State private var existingNames: [String] = []
    @State private var loadError: MCPConfigError?

    private let monospaced = Font.system(size: 12.5, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.serverName == nil ? "Nuevo MCP" : "Editar MCP").font(.headline)
            Form {
                TextField("Nombre", text: $form.name, prompt: Text("laravel-boost"))
                LabeledContent("Tipo") {
                    MCPTypePicker(remote: $form.remote)
                }
                if form.remote {
                    TextField("URL", text: $form.url, prompt: Text("https://ejemplo.com/mcp"))
                } else {
                    LabeledContent("Comando") {
                        TextField("Comando", text: $form.commandLine, prompt: Text("php artisan boost:mcp"))
                            .labelsHidden()
                            .font(monospaced)
                    }
                    LabeledContent("Entorno") {
                        environmentEditor
                    }
                }
            }
            if let message = problem {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Se guarda en .mcp.json del repo. Claude lo lee directo; Hive se lo pasa a Codex y Gemini al abrir cada sesión.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let serverName = target.serverName {
                    Button("Quitar", role: .destructive) {
                        store.removeMCP(serverName, projectId: target.projectId)
                        dismiss()
                    }
                    .foregroundStyle(.red)
                    .disabled(loadError != nil)
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await load() }
    }

    /// Un TextEditor que se ve como campo: fondo, borde y un texto de ejemplo cuando está vacío.
    private var environmentEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $form.environment)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
            if form.environment.isEmpty {
                Text("CLAVE=valor, una por línea")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 72)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    }

    private var nameIsTaken: Bool { form.nameIsTaken(by: existingNames, editing: target.serverName) }

    private var canSave: Bool { form.canSave && !nameIsTaken && loadError == nil }

    /// Por qué no se puede guardar, si hay algo para explicar.
    private var problem: String? {
        if loadError != nil { return ".mcp.json tiene un error de sintaxis: corregilo antes de editar los MCP." }
        if nameIsTaken { return "Ya hay un MCP con ese nombre en este proyecto." }
        if form.remote && !form.url.trimmingCharacters(in: .whitespaces).isEmpty && !form.isValidURL {
            return "La URL tiene que empezar con http:// o https://."
        }
        return nil
    }

    private func load() async {
        guard let project = store.project(target.projectId) else { return }
        let path = project.path
        let result = await Task.detached(priority: .userInitiated) { MCPConfig.loadResult(dir: path) }.value
        switch result {
        case .success(let servers):
            existingNames = servers.map(\.name)
            if let serverName = target.serverName, let server = servers.first(where: { $0.name == serverName }) {
                original = server
                form = MCPServerForm(server: server)
            }
        case .failure(let error):
            loadError = error
        }
    }

    private func save() {
        store.saveMCP(form.apply(to: original), replacing: target.serverName, projectId: target.projectId)
        dismiss()
    }
}

/// «Comando local» o «URL remota», con la opción elegida en miel.
private struct MCPTypePicker: View {
    @Binding var remote: Bool

    var body: some View {
        HStack(spacing: 6) {
            option("Comando local", symbol: "terminal", value: false)
            option("URL remota", symbol: "globe", value: true)
        }
    }

    private func option(_ title: String, symbol: String, value: Bool) -> some View {
        let selected = remote == value
        return Button {
            remote = value
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.8) : Color.primary.opacity(0.1)))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
