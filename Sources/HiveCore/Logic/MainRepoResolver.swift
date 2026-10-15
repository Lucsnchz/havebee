import Foundation

/// Qué agregar a Hive cuando elegís una carpeta. Si es la de un worktree, el repo principal (y
/// después se abre la rama de ese worktree), así no aparece el mismo repo dos veces.
public enum MainRepoResolver {
    /// Lo que hace falta para agregar (o encontrar) el proyecto.
    public struct Found: Equatable, Sendable {
        /// Carpeta principal del repo.
        public var repo: String
        /// Rama actual de la carpeta principal (nil con HEAD desacoplado).
        public var head: String?
        /// Rama con la que arranca el proyecto en Hive (nil: sin ramas).
        public var initialBranch: String?
        /// `git worktree list` del repo (el primero es la carpeta principal).
        public var worktrees: [GitWorktree]
        /// Si elegiste la carpeta de un worktree: ese worktree.
        public var worktree: GitWorktree?

        public init(repo: String, head: String?, initialBranch: String?, worktrees: [GitWorktree], worktree: GitWorktree? = nil) {
            self.repo = repo
            self.head = head
            self.initialBranch = initialBranch
            self.worktrees = worktrees
            self.worktree = worktree
        }
    }

    /// Repo principal de una carpeta: `git worktree list` siempre lista primero la carpeta principal.
    /// Devuelve la carpeta principal y, si `top` es otro worktree, ese worktree.
    public static func mainRepo(top: String, worktrees: [GitWorktree]) -> (repo: String, worktree: GitWorktree?) {
        guard let main = worktrees.first, !samePath(main.path, top) else { return (top, nil) }
        return (main.path, worktrees.first { samePath($0.path, top) } ?? GitWorktree(path: top))
    }

    /// Rama con la que arranca un proyecto: la actual. Con HEAD desacoplado no se inventa una rama
    /// «HEAD»: se usa la de origin/HEAD, o main, o master (la primera que haya). nil si no hay ninguna.
    public static func initialBranch(head: String?, originHead: String?, localBranches: [String]) -> String? {
        if let head, !head.isEmpty { return head }
        if let originHead, let slash = originHead.firstIndex(of: "/") {
            let name = String(originHead[originHead.index(after: slash)...])
            if !name.isEmpty && name != "HEAD" { return name }
        }
        return ["main", "master"].first { localBranches.contains($0) }
    }

    /// Lee git para una carpeta elegida. Bloquea: llamarlo fuera del hilo principal. nil si no es un repo.
    public static func inspect(_ path: String, git: GitClient) -> Found? {
        guard let top = git.topLevel(path) else { return nil }
        var worktrees = git.worktrees(top)
        var (repo, worktree) = mainRepo(top: top, worktrees: worktrees)
        // Un repo «bare» no tiene carpeta de trabajo: en ese caso se agrega el worktree tal cual.
        if worktree != nil, git.topLevel(repo) == nil {
            repo = top
            worktree = nil
            worktrees = worktrees.filter { samePath($0.path, top) }
        }
        let head = git.currentBranch(repo)
        let initial = head != nil ? head : initialBranch(head: nil, originHead: originHead(repo, git: git),
                                                         localBranches: git.localBranches(repo))
        return Found(repo: repo, head: head, initialBranch: initial, worktrees: worktrees, worktree: worktree)
    }

    /// La rama por defecto del remoto principal ("origin/main"), si la hay: origin/HEAD o, si no
    /// está configurado, main, master, develop o trunk del remoto. Sale de `GitClient`, así que
    /// también funciona con cualquier cliente (no solo con el git del sistema).
    public static func originHead(_ dir: String, git: GitClient) -> String? {
        git.defaultRemoteBranch(dir)
    }
}
