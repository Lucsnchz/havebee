import HiveCore
import SwiftUI

/// Barra de estado debajo de la terminal de una sesión: la rama con sus commits y cambios a la
/// izquierda, y los comandos de esa rama a la derecha. Así nada tapa el prompt del agente.
struct SessionStatusBar: View {
    @Environment(AppStore.self) private var store
    @AppStorage("sessionSidePanel") private var sidePanel = ""
    let project: Project
    let branch: Branch
    /// El agente se pasó a otra rama: se muestra esa, con sus commits y cambios.
    var drift: AgentDrift? = nil

    static let height: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                place
                Spacer(minLength: 12)
                commands
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
        }
        .font(.system(size: 11))
        .background(.bar)
    }

    // MARK: - Rama

    @ViewBuilder
    private var place: some View {
        if project.isScratch {
            Label {
                Text((project.directory(for: branch) as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .foregroundStyle(.secondary)
        } else {
            let status = drift.map(store.gitStatus(for:)) ?? store.gitStatus(for: branch, in: project)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                if let drift {
                    Text(branch.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    DriftedBranch(drift: drift, maxLength: 40)
                        .help(DriftedBranch.description(drift, from: branch))
                } else {
                    Text(status?.branch ?? branch.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let status {
                    if status.ahead > 0 {
                        separator
                        Text("↑\(status.ahead)")
                            .monospacedDigit()
                            .help(status.ahead == 1 ? "Un commit sin pushear" : "\(status.ahead) commits sin pushear")
                    }
                    if status.behind > 0 {
                        separator
                        Text("↓\(status.behind)")
                            .monospacedDigit()
                            .help(status.behind == 1 ? "Un commit sin traer" : "\(status.behind) commits sin traer")
                    }
                    separator
                    Button {
                        sidePanel = sidePanel == "changes" ? "" : "changes"
                    } label: {
                        // El mismo ± que en el sidebar, las tarjetas y el botón «Cambios» de arriba.
                        HStack(spacing: 3) {
                            Image(systemName: GitCounters.changesSymbol)
                                .font(.system(size: 9, weight: .semibold))
                            Text(Self.changesLabel(status.changes.count))
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ver los cambios de la rama")
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    static func changesLabel(_ count: Int) -> String {
        switch count {
        case 0: "Sin cambios"
        case 1: "1 cambio"
        default: "\(count) cambios"
        }
    }

    // MARK: - Comandos

    private var commands: some View {
        HStack(spacing: 6) {
            ForEach(store.commandRuns.filter { $0.branchId == branch.id }) { run in
                CommandChip(run: run)
            }
        }
    }
}

/// Un comando de la rama («● Servidor»). Al tocarlo muestra su salida en un popover.
private struct CommandChip: View {
    let run: CommandRun
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 5) {
                CommandRunDot(run: run, size: 6)
                Text(run.name)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(showing ? 0.14 : 0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(run.command) · \(CommandRunDot.label(run))")
        .accessibilityLabel("\(run.name), \(CommandRunDot.label(run))")
        .popover(isPresented: $showing, arrowEdge: .top) {
            CommandRunPanel(run: run)
                .frame(width: 560)
        }
    }
}

/// «→ mensajes»: la rama a la que se pasó el agente (ver `AgentDrift`), en la pestaña, el árbol y la
/// barra de estado, al lado de la rama de la sesión.
struct DriftedBranch: View {
    let drift: AgentDrift
    var maxLength = 20

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
                .accessibilityHidden(true)
            Text(drift.branchName.middleTruncated(max: maxLength))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Theme.info)
    }

    /// La explicación al pasar el mouse: dónde está y adónde vuelve si se reinicia.
    static func description(_ drift: AgentDrift, from branch: Branch) -> String {
        "El agente trabaja en «\(drift.branchName)» (\(drift.directory.tildePath)). Si reiniciás la sesión, vuelve a «\(branch.name)»."
    }
}
