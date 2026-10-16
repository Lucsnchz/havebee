import AppKit
import HiveCore
import SwiftUI

/// «Abrir sitio»: la URL de la rama según polyscope.json o Herd. Si no hay ninguna, no se muestra.
/// Con `url` ya calculada (la barra de la sesión la calcula antes de poner el botón, para no dejar
/// una cápsula vacía en la barra), no lee nada.
struct OpenSiteButton: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    private let known: String?
    @State private var url: String?

    init(project: Project, branch: Branch) {
        self.project = project
        self.branch = branch
        known = nil
    }

    init(project: Project, branch: Branch, url: String) {
        self.project = project
        self.branch = branch
        known = url
    }

    var body: some View {
        content
            .task(id: "\(project.directory(for: branch))|\(branch.setupCommand == nil)") {
                guard known == nil else { return }
                url = await Self.loadURL(project: project, branch: branch, home: store.environment.home)
            }
    }

    @ViewBuilder private var content: some View {
        if let url = known ?? url {
            Menu {
                Button {
                    BrowserLink.open(url)
                } label: {
                    Label("Abrir en el navegador", systemImage: "safari")
                }
                Button {
                    ExternalApps.copyToPasteboard(url)
                } label: {
                    Label("Copiar URL", systemImage: "doc.on.doc")
                }
            } label: {
                Label("Abrir sitio", systemImage: "globe")
            } primaryAction: {
                BrowserLink.open(url)
            }
            .help("Abrir \(url)")
        } else {
            // Sin URL no ocupa lugar, pero sigue ahí para calcularla.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Lee polyscope.json y la configuración de Herd fuera del hilo principal.
    static func loadURL(project: Project, branch: Branch, home: URL) async -> String? {
        let dir = project.directory(for: branch)
        let projectPath = project.path
        return await Task.detached(priority: .utility) {
            let herd = HerdSites.parse(configRoot: HerdSites.defaultRoot(home: home))
            return SiteURL.url(for: dir, projectPath: projectPath, herd: herd)
        }.value
    }
}

/// Abre una página web en el navegador. Solo http y https: nunca un archivo, una app ni otro esquema.
enum BrowserLink {
    static func url(_ text: String) -> URL? {
        guard SiteURL.isWebURL(text) else { return nil }
        // Los corchetes de las URLs de MR de GitLab no son válidos sin escapar en todas las versiones de URL.
        let link = URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
        guard let scheme = link?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return link
    }

    static func open(_ text: String) {
        guard let link = url(text) else { return }
        NSWorkspace.shared.open(link)
    }
}
