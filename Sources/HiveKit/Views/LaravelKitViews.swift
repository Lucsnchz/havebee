import HiveCore
import SwiftUI

/// «Laravel y agentes» en el resumen del proyecto: qué le falta para que los agentes trabajen bien
/// (Boost, PAO, los MCP de Nightwatch y Herd, los tests afectados) y un botón que lo prepara. Lo que
/// se instala corre en una terminal a la vista; los MCP y los comandos los guarda Havebee.
struct LaravelKitSection: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var kit: LaravelAgentKit?
    @State private var loaded = false
    /// Pendientes que destildaste: los demás se preparan.
    @State private var unticked: Set<LaravelAgentKit.Step> = []
    @State private var reloadToken = 0

    static let runName = "Preparar para agentes"

    /// Dos stats (`artisan` y composer.json): se puede llamar al dibujar el resumen.
    static func isLaravel(_ path: String) -> Bool {
        ["artisan", "composer.json"].allSatisfy { FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
    }

    private var selected: Set<LaravelAgentKit.Step> {
        Set((kit?.pending ?? []).map(\.step)).subtracting(unticked)
    }

    /// Si la preparación está corriendo: al terminar se vuelve a leer el proyecto.
    private var preparing: Bool {
        store.commandRuns.contains { $0.projectId == project.id && $0.name == Self.runName && $0.running }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let kit {
                VStack(spacing: 0) {
                    ForEach(Array(kit.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 40) }
                        row(item)
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: HiveCard.rowRadius))
                .overlay(RoundedRectangle(cornerRadius: HiveCard.rowRadius).strokeBorder(Color.primary.opacity(0.08)))

                if kit.pending.isEmpty {
                    Label("Todo listo para los agentes.", systemImage: "checkmark.seal.fill")
                        .font(HiveFont.secondary)
                        .foregroundStyle(Theme.accent)
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Button {
                            prepare(kit)
                        } label: {
                            Label(preparing ? "Preparando…" : Self.runName, systemImage: "wand.and.stars")
                        }
                        .controlSize(.large)
                        .disabled(selected.isEmpty || preparing)
                        .help("Instala y configura lo tildado")
                        Text("Lo que se instala corre en una terminal a la vista. Revisá composer.json antes del commit.")
                            .font(HiveFont.meta)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if loaded {
                Text("No pude leer composer.json: revisá que sea un JSON válido.")
                    .font(HiveFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(project.path)|\(store.mcpVersion)|\(project.commands.map(\.command))|\(preparing)|\(reloadToken)") {
            let path = project.path
            let home = store.environment.home
            let commands = project.commands
            let loaded = await Task.detached(priority: .utility) { () -> LaravelAgentKit? in
                let herd = FileManager.default.fileExists(atPath: HerdSites.defaultRoot(home: home).appendingPathComponent("bin/herd").path)
                return LaravelAgentKit.inspect(projectPath: path, home: home, servers: MCPConfig.load(dir: path),
                                               commands: commands, herdInstalled: herd)
            }.value
            guard !Task.isCancelled else { return }
            kit = loaded
            self.loaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadToken += 1
        }
    }

    private func row(_ item: LaravelAgentKit.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if item.done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Listo")
                } else {
                    Toggle(item.title, isOn: Binding(
                        get: { !unticked.contains(item.step) },
                        set: { on in if on { unticked.remove(item.step) } else { unticked.insert(item.step) } }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(HiveFont.body.weight(.medium))
                Text(item.detail)
                    .font(HiveFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(item.done ? 0.75 : 1)
    }

    private func prepare(_ kit: LaravelAgentKit) {
        let steps = selected
        for change in kit.servers(steps) {
            store.saveMCP(change.server, replacing: change.replacing, projectId: project.id)
        }
        if steps.contains(.fastTests), let command = kit.fastTestsCommand, !project.commands.contains(where: { $0.command == command }) {
            store.saveCommand(projectId: project.id, commandId: nil, name: "Tests afectados", command: command)
        }
        if let script = kit.script(steps) {
            let branch = store.defaultBranch(for: project) ?? project.branches.first { $0.mode == .main }
            if let branch {
                store.runScript(name: Self.runName, command: script, projectId: project.id, branchId: branch.id)
            } else {
                store.alert = AppAlert(title: "No pude preparar «\(project.name)»",
                                       message: "Agregá a Havebee la rama de la carpeta principal y probá de nuevo.")
            }
        }
        unticked = []
        reloadToken += 1
    }
}
