import Foundation
import Testing
@testable import HiveCore

@Suite("Remotos de GitLab y GitHub")
struct RemoteHostTests {
    @Test("ssh, ssh:// y https, con subgrupos, usuario, puerto y .git", arguments: [
        ("git@gitlab.com:dizeg/emplag-v2.git", RemoteHost.Kind.gitlab, "gitlab.com", "dizeg/emplag-v2"),
        ("git@gitlab.com:dizeg/backend/api.git", .gitlab, "gitlab.com", "dizeg/backend/api"),
        ("ssh://git@gitlab.example.com:2222/grupo/repo.git", .gitlab, "gitlab.example.com", "grupo/repo"),
        ("https://gitlab.com/dizeg/bevo.git", .gitlab, "gitlab.com", "dizeg/bevo"),
        ("https://oauth2:token@gitlab.com/dizeg/bevo", .gitlab, "gitlab.com", "dizeg/bevo"),
        ("git@github.com:apple/swift.git", .github, "github.com", "apple/swift"),
        ("https://github.com/apple/swift/", .github, "github.com", "apple/swift"),
        ("git@bitbucket.org:equipo/repo.git", .other, "bitbucket.org", "equipo/repo"),
    ] as [(String, RemoteHost.Kind, String, String)])
    func parse(url: String, kind: RemoteHost.Kind, host: String, path: String) throws {
        let remote = try #require(RemoteHost.parse(url))
        #expect(remote.kind == kind && remote.host == host && remote.path == path)
        #expect(remote.webURL == "https://\(host)/\(path)")
    }

    @Test("El puerto de https queda en la web; el de ssh no")
    func ports() throws {
        let https = try #require(RemoteHost.parse("https://git.empresa.com:8443/equipo/app.git"))
        #expect(https.webURL == "https://git.empresa.com:8443/equipo/app")
        #expect(try #require(RemoteHost.parse("https://gitlab.com:443/dizeg/bevo.git")).webURL == "https://gitlab.com/dizeg/bevo")
        #expect(try #require(RemoteHost.parse("ssh://git@gitlab.empresa.com:2222/equipo/app.git")).webURL == "https://gitlab.empresa.com/equipo/app")
    }

    @Test("Publicada: sigue a su par en el remoto, que existe, y sin commits sin subir")
    func published() {
        #expect(RemoteHost.isPublished(branch: "feature/x", upstream: "origin/feature/x", gone: false, ahead: 0))
        #expect(!RemoteHost.isPublished(branch: "feature/x", upstream: "origin/feature/x", gone: false, ahead: 2))
        #expect(!RemoteHost.isPublished(branch: "feature/x", upstream: "origin/feature/x", gone: true, ahead: 0))
        #expect(!RemoteHost.isPublished(branch: "feature/x", upstream: nil, gone: false, ahead: 0))
        // `git checkout -b feature/x origin/main` deja origin/main como upstream: eso no es estar publicada.
        #expect(!RemoteHost.isPublished(branch: "feature/x", upstream: "origin/main", gone: false, ahead: 0))
        #expect(!RemoteHost.isPublished(branch: "x", upstream: "origin/feature/x", gone: false, ahead: 0))
        #expect(RemoteHost.isPublished(branch: "x", upstream: "upstream/x", gone: false, ahead: 0))
    }

    @Test("Lo que no es un remoto web devuelve nil", arguments: ["/ruta/local/repo.git", "", "file:///tmp/r.git", "git@gitlab.com:solo"])
    func invalid(url: String) {
        #expect(RemoteHost.parse(url) == nil)
    }

    @Test("URL de nuevo MR en GitLab, con las ramas escapadas")
    func gitlabMergeRequest() throws {
        let remote = try #require(RemoteHost.parse("git@gitlab.com:dizeg/backend/api.git"))
        #expect(remote.newMergeRequestURL(source: "feature/checkout", target: "main")
                == "https://gitlab.com/dizeg/backend/api/-/merge_requests/new?merge_request[source_branch]=feature/checkout&merge_request[target_branch]=main")
        let odd = try #require(remote.newMergeRequestURL(source: "fix/a&b #1+ñ", target: "release 2"))
        #expect(odd.hasSuffix("source_branch]=fix/a%26b%20%231%2B%C3%B1&merge_request[target_branch]=release%202"))
        #expect(remote.branchMergeRequestsURL("feature/x") == "https://gitlab.com/dizeg/backend/api/-/merge_requests?scope=all&state=opened&source_branch=feature/x")
        #expect(remote.pipelinesURL("feature/x") == "https://gitlab.com/dizeg/backend/api/-/pipelines?ref=feature/x")
        #expect(remote.newRequestLabel == "Crear MR en GitLab")
    }

    @Test("GitHub usa compare; otros servidores no tienen MR")
    func others() throws {
        let github = try #require(RemoteHost.parse("git@github.com:apple/swift.git"))
        #expect(github.newMergeRequestURL(source: "feature/x", target: "main") == "https://github.com/apple/swift/compare/main...feature/x?expand=1")
        #expect(github.compareURL(base: "main", branch: "a b") == "https://github.com/apple/swift/compare/main...a%20b?expand=1")
        #expect(github.pipelinesURL("x") == "https://github.com/apple/swift/actions?query=branch%3Ax")
        #expect(github.newRequestLabel == "Crear PR en GitHub")
        let other = try #require(RemoteHost.parse("git@bitbucket.org:equipo/repo.git"))
        #expect(other.newMergeRequestURL(source: "x", target: "main") == nil)
        #expect(other.pipelinesURL("x") == nil)
    }
}
