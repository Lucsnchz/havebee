import AppKit
import HiveCore
import SwiftUI

/// Traer, publicar y abrir el MR de la rama en GitLab (o el PR en GitHub) sin instalar nada.
/// Si el repo no tiene remotos, no se muestra.
struct RemoteActionsMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    @State private var hasRemote = false
    @State private var remote: RemoteHost?
    /// Rama por defecto del remoto, sin el prefijo ("main").
    @State private var defaultBase: String?
    /// Para mostrar el spinner ya andando (las capturas de los tests).
    private let previewBusy: String?

    init(project: Project, branch: Branch, busy: String? = nil) {
        self.project = project
        self.branch = branch
        previewBusy = busy
    }

    /// Lo que se está haciendo, para el spinner. Lo guarda el store y no esta vista, que se arma de
    /// nuevo al cambiar de sesión: con un pre-push de varios minutos, al volver sigue el spinner con su X.
    private var busy: String? { previewBusy ?? store.remoteOperations[branch.id]?.label }

    var body: some View {
        content
            .task(id: project.path) { await load() }
    }

    @ViewBuilder private var content: some View {
        if hasRemote {
            HStack(spacing: 6) {
                if let busy {
                    ProgressView()
                        .controlSize(.small)
                        .help(busy)
                    Button {
                        store.cancelRemoteOperation(branchId: branch.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancelar: corta git y lo que esté corriendo (un hook pre-push, por ejemplo)")
                    .accessibilityLabel("Cancelar")
                }
                Menu {
                    menuItems
                } label: {
                    Label(remote?.kind == .gitlab ? "GitLab" : remote?.kind == .github ? "GitHub" : "Remoto",
                          systemImage: "arrow.up.arrow.down")
                }
                .disabled(busy != nil)
                .help("Traer, publicar y crear el \(remote?.kind == .github ? "PR" : "MR") de «\(branch.name)»")
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder private var menuItems: some View {
        let active = store.isActive(branch, in: project)
        Button {
            perform("Trayendo cambios…", title: "No se pudieron traer los cambios", cancelled: "Cancelaste «Traer cambios»") { git, dir, _ in
                git.pull(ffOnly: true, in: dir)
            }
        } label: {
            Label("Traer cambios", systemImage: "arrow.down.circle")
        }
        .disabled(!active)
        .help(active ? "git pull --ff-only" : "Hacé checkout de la rama para traer sus cambios")
        Button {
            perform("Publicando…", title: "No se pudo publicar la rama", cancelled: "Cancelaste la publicación de «\(branch.name)»") { git, dir, name in
                git.push(branch: name, setUpstream: true, in: dir)
            }
        } label: {
            Label("Publicar rama", systemImage: "arrow.up.circle")
        }
        if let remote, remote.kind != .other {
            Divider()
            Button {
                createMergeRequest(remote)
            } label: {
                Label(remote.newRequestLabel, systemImage: "arrow.triangle.pull")
            }
            if let mergeRequests = remote.branchMergeRequestsURL(branch.name) {
                Button {
                    BrowserLink.open(mergeRequests)
                } label: {
                    Label(remote.kind == .gitlab ? "Ver MRs de la rama" : "Ver PRs de la rama", systemImage: "list.bullet")
                }
            }
            if let pipelines = remote.pipelinesURL(branch.name) {
                Button {
                    BrowserLink.open(pipelines)
                } label: {
                    Label(remote.kind == .gitlab ? "Ver pipelines" : "Ver Actions", systemImage: "gearshape.2")
                }
            }
        }
    }

    private func load() async {
        let git = store.git
        let path = project.path
        let (url, base) = await Task.detached(priority: .utility) {
            (git.remoteURL(path), git.defaultRemoteBranch(path))
        }.value
        hasRemote = url != nil
        remote = url.flatMap(RemoteHost.parse)
        defaultBase = base.map { ref in ref.firstIndex(of: "/").map { String(ref[ref.index(after: $0)...]) } ?? ref }
    }

    /// Corre una operación de git fuera del hilo principal, cancelable con la X junto al spinner; si
    /// falla, avisa con una alerta, y si la cancelaste, con un aviso corto. Una sola por rama.
    private func perform(_ label: String, title: String, cancelled: String,
                         _ work: @escaping @Sendable (GitClient, String, String) -> CommandResult,
                         then success: (() -> Void)? = nil) {
        store.runRemoteOperation(branchId: branch.id, directory: project.directory(for: branch), branchName: branch.name,
                                 label: label, failureTitle: title, cancelledNotice: cancelled, work, then: success)
    }

    /// Publica la rama si hace falta y abre la página del MR nuevo contra la rama por defecto.
    private func createMergeRequest(_ remote: RemoteHost) {
        let status = store.gitStatus(for: branch, in: project)
        let target = defaultBase ?? "main"
        guard let url = remote.newMergeRequestURL(source: branch.name, target: target) else { return }
        // Publicada = sigue a su par en el remoto (no a origin/main, como deja `git checkout -b x origin/main`)
        // y no tiene commits sin subir.
        let published = status.map { RemoteHost.isPublished(branch: branch.name, upstream: $0.upstream, gone: $0.upstreamGone, ahead: $0.ahead) } ?? false
        if published {
            BrowserLink.open(url)
            return
        }
        perform("Publicando…", title: "No se pudo publicar la rama", cancelled: "Cancelaste la publicación de «\(branch.name)»", { git, dir, name in
            git.push(branch: name, setUpstream: true, in: dir)
        }, then: { BrowserLink.open(url) })
    }
}
