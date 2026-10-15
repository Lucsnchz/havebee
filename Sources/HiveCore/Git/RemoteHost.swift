import Foundation

/// El servidor de un remoto de git (GitLab, GitHub u otro) y sus páginas web: nuevo Merge Request,
/// MRs de una rama y pipelines. No hace falta glab ni gh: alcanza con abrir la URL.
public struct RemoteHost: Equatable, Sendable {
    public enum Kind: String, Sendable { case gitlab, github, other }

    public var kind: Kind
    /// "gitlab.com"
    public var host: String
    /// "grupo/subgrupo/repo", sin .git.
    public var path: String

    public init(kind: Kind, host: String, path: String) {
        self.kind = kind
        self.host = host
        self.path = path
    }

    /// "https://gitlab.com/grupo/subgrupo/repo"
    public var webURL: String { "https://\(host)/\(path)" }

    /// Lo que dice el botón: «Crear MR en GitLab», «Crear PR en GitHub».
    public var newRequestLabel: String {
        switch kind {
        case .gitlab: "Crear MR en GitLab"
        case .github: "Crear PR en GitHub"
        case .other: "Abrir el repo en la web"
        }
    }

    /// Entiende `git@host:ns/repo.git`, `ssh://git@host:2222/ns/repo.git` y `https://usuario@host/ns/repo.git`.
    public static func parse(_ remoteURL: String) -> RemoteHost? {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var host: String
        var path: String
        if url.contains("://") {
            guard let components = URLComponents(string: url), let parsedHost = components.host, !parsedHost.isEmpty,
                  ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(components.scheme?.lowercased() ?? "") else { return nil }
            host = parsedHost
            path = components.path
        } else if let colon = url.firstIndex(of: ":"), !url.hasPrefix("/") {
            // Sintaxis scp: [usuario@]host:ruta
            var authority = String(url[..<colon])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            host = authority
            path = String(url[url.index(after: colon)...])
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        host = host.lowercased()
        guard !host.isEmpty, !path.isEmpty, path.contains("/") else { return nil }
        let kind: Kind = host.contains("gitlab") ? .gitlab : host == "github.com" || host.hasSuffix(".github.com") ? .github : .other
        return RemoteHost(kind: kind, host: host, path: path)
    }

    /// Página para crear un MR (GitLab) o un PR (GitHub) de `source` hacia `target`.
    public func newMergeRequestURL(source: String, target: String) -> String? {
        switch kind {
        case .gitlab:
            return "\(webURL)/-/merge_requests/new?merge_request[source_branch]=\(Self.encode(source))"
                + "&merge_request[target_branch]=\(Self.encode(target))"
        case .github:
            return compareURL(base: target, branch: source)
        case .other:
            return nil
        }
    }

    /// MRs abiertos de una rama.
    public func branchMergeRequestsURL(_ branch: String) -> String? {
        switch kind {
        case .gitlab: "\(webURL)/-/merge_requests?scope=all&state=opened&source_branch=\(Self.encode(branch))"
        case .github: "\(webURL)/pulls?q=" + Self.encode("is:pr is:open head:\(branch)")
        case .other: nil
        }
    }

    /// Pipelines (GitLab) o Actions (GitHub) de una rama.
    public func pipelinesURL(_ branch: String) -> String? {
        switch kind {
        case .gitlab: "\(webURL)/-/pipelines?ref=\(Self.encode(branch))"
        case .github: "\(webURL)/actions?query=" + Self.encode("branch:\(branch)")
        case .other: nil
        }
    }

    /// GitHub: comparar `branch` contra `base`, con el formulario de PR abierto.
    public func compareURL(base: String, branch: String) -> String {
        "\(webURL)/compare/\(Self.encode(base))...\(Self.encode(branch))?expand=1"
    }

    /// Escapa un valor de la query: deja letras, números, «-._~» y «/» (los nombres de rama los usan mucho).
    static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
