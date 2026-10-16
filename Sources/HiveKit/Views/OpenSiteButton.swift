import AppKit
import HiveCore
import SwiftUI

/// «Abrir sitio»: la URL de la rama según polyscope.json o Herd. Si no hay ninguna, no se muestra.
struct OpenSiteButton: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    @State private var url: String?

    var body: some View {
        content
            .task(id: project.directory(for: branch)) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let url {
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
    private func load() async {
        let dir = project.directory(for: branch)
        let projectPath = project.path
        let home = store.environment.home
        url = await Task.detached(priority: .utility) {
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
