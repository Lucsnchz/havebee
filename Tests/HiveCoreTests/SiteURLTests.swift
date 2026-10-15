import Foundation
import Testing
@testable import HiveCore

@Suite("URL del sitio de una rama")
struct SiteURLTests {
    let herd = HerdSites(tld: "test", parkedPaths: ["/Users/x/Herd"], securedHosts: ["app.test"])

    @Test("polyscope.json preview.url gana, con {{folder}} reemplazado")
    func polyscopeFirst() {
        let files = ["/Users/x/Herd/app/polyscope.json": #"{"preview": {"url": "https://{{ folder }}.test/login"}}"#]
        let url = SiteURL.url(for: "/Users/x/Herd/app-checkout", projectPath: "/Users/x/Herd/app", herd: herd, read: { files[$0] })
        #expect(url == "https://app-checkout.test/login")
    }

    @Test("El polyscope.json del worktree tiene prioridad sobre el de la carpeta principal")
    func worktreeFile() {
        let files = [
            "/w/polyscope.json": #"{"preview": {"url": "http://{{folder}}.local"}}"#,
            "/p/polyscope.json": #"{"preview": {"url": "http://principal.local"}}"#,
        ]
        #expect(SiteURL.url(for: "/w", projectPath: "/p", herd: nil, read: { files[$0] }) == "http://w.local")
    }

    @Test("Sin polyscope.json usa Herd; sin nada, nil")
    func herdFallback() {
        #expect(SiteURL.url(for: "/Users/x/Herd/app", projectPath: "/Users/x/Herd/app", herd: herd, read: { _ in nil }) == "https://app.test")
        #expect(SiteURL.url(for: "/Users/x/Herd/app-x", projectPath: "/Users/x/Herd/app", herd: herd, read: { _ in nil }) == "http://app-x.test")
        #expect(SiteURL.url(for: "/otro/lado", projectPath: "/otro/lado", herd: herd, read: { _ in nil }) == nil)
        #expect(SiteURL.url(for: "/otro/lado", projectPath: "/otro/lado", herd: nil, read: { _ in "{}" }) == nil)
    }

    @Test("Plantillas")
    func fill() {
        #expect(SiteURL.fill("https://{{folder}}.test", folder: "a-b") == "https://a-b.test")
        #expect(SiteURL.fill("https://fijo.test", folder: "a") == "https://fijo.test")
        #expect(SiteURL.fill("{{folder}}/{{folder}}", folder: "$1") == "$1/$1")
    }
}
