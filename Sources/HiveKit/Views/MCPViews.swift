import AppKit
import HiveCore
import SwiftUI

/// MCP del proyecto (`.mcp.json`), sugerencias por stack y los globales de cada agente.
struct MCPSection: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var showGlobals = false

    var body: some View {
        let _ = store.mcpVersion // vuelve a leer el archivo cuando Hive lo cambia
        let servers = MCPConfig.load(dir: project.path)
        let suggestions = store.mcpSuggestions(for: project, existing: servers)
        VStack(alignment: .leading, spacing: 8) {
            if servers.isEmpty {
                Text("Este proyecto no tiene MCP. Se guardan en .mcp.json del repo: Claude los lee directo y Hive se los pasa a Codex y Gemini.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(servers) { server in
                MCPRow(project: project, server: server)
            }
            HStack(spacing: 8) {
                Button {
                    store.mcpEditor = MCPEditorTarget(projectId: project.id, serverName: nil)
                } label: {
                    Label("Agregar MCP", systemImage: "plus")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([MCPConfig.url(in: project.path)])
                } label: {
                    Label(".mcp.json", systemImage: "doc.text")
                }
                .buttonStyle(.borderless)
                .disabled(!FileManager.default.fileExists(atPath: MCPConfig.url(in: project.path).path))
            }
            if !suggestions.isEmpty {
                Text("Sugeridos para este proyecto")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8)], spacing: 8) {
                    ForEach(suggestions) { item in
                        CatalogCard(item: item) {
                            store.saveMCP(MCPServer(name: item.name, config: item.config), replacing: nil, projectId: project.id)
                        }
                    }
                }
            }
            GlobalMCPs(project: project, expanded: $showGlobals)
                .padding(.top, 6)
        }
    }
}

private struct MCPRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let server: MCPServer
    @State private var hovering = false

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
                if let broken = server.brokenPath {
                    Label("La ruta no existe en esta Mac: \(broken)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach([SessionKind.claude, .codex, .gemini]) { AgentLogo(kind: $0, size: 13) }
            }
            .help("Disponible para Claude, Codex y Gemini")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.mcpEditor = MCPEditorTarget(projectId: project.id, serverName: server.name) }
        .contextMenu {
            Button("Editar…") { store.mcpEditor = MCPEditorTarget(projectId: project.id, serverName: server.name) }
            Button("Quitar") { store.removeMCP(server.name, projectId: project.id) }
        }
    }
}

private struct CatalogCard: View {
    let item: MCPCatalog.Item
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 12.5, weight: .semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Agregar", action: add)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(hovering ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onHover { hovering = $0 }
    }
}

private struct GlobalMCPs: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("MCP globales de cada agente")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                let groups = store.mcpGlobals(for: project)
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
            }
        }
    }
}

/// Editor de un MCP del proyecto.
struct MCPEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: MCPEditorTarget

    @State private var name = ""
    @State private var remote = false
    @State private var commandLine = ""
    @State private var url = ""
    @State private var envText = ""
    @State private var original: [String: JSONValue] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.serverName == nil ? "Nuevo MCP" : "Editar MCP").font(.headline)
            Form {
                TextField("Nombre", text: $name, prompt: Text("laravel-boost"))
                Picker("Tipo", selection: $remote) {
                    Text("Comando local").tag(false)
                    Text("URL remota").tag(true)
                }
                .pickerStyle(.segmented)
                if remote {
                    TextField("URL", text: $url, prompt: Text("https://ejemplo.com/mcp"))
                } else {
                    TextField("Comando", text: $commandLine, prompt: Text("php artisan boost:mcp"))
                        .font(.body.monospaced())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Variables de entorno (una por línea, CLAVE=valor)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $envText)
                            .font(.body.monospaced())
                            .frame(height: 70)
                    }
                }
            }
            Text("Se guarda en .mcp.json del repo. Claude lo lee directo; Hive se lo pasa a Codex y Gemini al abrir cada sesión.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let serverName = target.serverName {
                    Button("Quitar", role: .destructive) {
                        store.removeMCP(serverName, projectId: target.projectId)
                        dismiss()
                    }
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
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (remote ? !url.trimmingCharacters(in: .whitespaces).isEmpty : !commandLine.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func load() {
        guard let serverName = target.serverName, let project = store.project(target.projectId),
              let server = MCPConfig.load(dir: project.path).first(where: { $0.name == serverName }) else { return }
        name = server.name
        original = server.config
        remote = server.isRemote
        url = server.url ?? ""
        commandLine = ([server.command ?? ""] + server.args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }).joined(separator: " ")
        envText = server.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private func save() {
        var config = original
        if remote {
            for key in ["command", "args", "env"] { config.removeValue(forKey: key) }
            config["type"] = "http"
            config["url"] = .string(url.trimmingCharacters(in: .whitespaces))
        } else {
            for key in ["url", "httpUrl", "type"] { config.removeValue(forKey: key) }
            let words = MCPConfig.splitCommandLine(commandLine)
            config["command"] = .string(words.first ?? "")
            if words.count > 1 { config["args"] = .array(words.dropFirst().map(JSONValue.string)) } else { config.removeValue(forKey: "args") }
            var env: [String: String] = [:]
            for line in envText.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty { env[parts[0]] = parts[1] }
            }
            if env.isEmpty { config.removeValue(forKey: "env") } else { config["env"] = .object(env.mapValues(JSONValue.string)) }
        }
        let server = MCPServer(name: name.trimmingCharacters(in: .whitespaces), config: config)
        store.saveMCP(server, replacing: target.serverName, projectId: target.projectId)
        dismiss()
    }
}
