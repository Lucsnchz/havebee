import Foundation

/// Los repos que muestra Hive como carpetas para mirar: la principal, sus worktrees y dónde guarda
/// git la rama actual, las ramas, el índice y la lista de worktrees.
public struct GitLayout: Equatable, Sendable {
    public struct Repository: Equatable, Sendable {
        /// La carpeta principal.
        public var path: String
        public var worktrees: [String]
        /// Donde guarda git sus datos: casi siempre `<path>/.git`. Un commit, un checkout o un
        /// `git add` en cualquiera de sus carpetas cambia algo acá.
        public var gitDirectories: [String]

        public init(path: String, worktrees: [String], gitDirectories: [String]) {
            self.path = path
            self.worktrees = worktrees
            self.gitDirectories = gitDirectories
        }

        /// Busca en el disco dónde guarda git los datos de la carpeta principal.
        public init(path: String, worktrees: [String]) {
            self.init(path: path, worktrees: worktrees, gitDirectories: GitLayout.gitDirectories(of: path))
        }

        /// La principal y los worktrees: las carpetas que tienen un `git status`.
        public var trees: [String] { [path] + worktrees }
    }

    public var repositories: [Repository]

    public init(repositories: [Repository]) {
        self.repositories = repositories
    }

    /// Las carpetas a mirar.
    public var roots: Set<String> {
        Set(repositories.flatMap { $0.trees + $0.gitDirectories })
    }

    /// Dónde guarda git los datos de `dir`: su `.git` o, si `.git` es un archivo que apunta a otro
    /// lado (un worktree, un submódulo), esa carpeta y la común, donde están las ramas. Sin correr
    /// git, porque se busca en cada revisión.
    public static func gitDirectories(of dir: String) -> [String] {
        let dotGit = (dir as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return [] }
        if isDirectory.boolValue { return [dotGit] }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let gitDir = GitParsing.gitDirPointer(text, relativeTo: dir) else { return [] }
        let commonFile = (gitDir as NSString).appendingPathComponent("commondir")
        guard let common = try? String(contentsOfFile: commonFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !common.isEmpty else { return [gitDir] }
        let full = common.hasPrefix("/") ? common : (gitDir as NSString).appendingPathComponent(common)
        return [gitDir, (full as NSString).standardizingPath]
    }
}

/// Lo de git que puede haber cambiado desde que Hive lo leyó, según dónde avisó macOS que hubo
/// cambios. Lo que no se sabe cuenta como cambiado.
public struct GitStaleness: Equatable, Sendable {
    /// Carpetas (principales y worktrees) cuyo `git status` puede haber cambiado.
    public private(set) var statuses: Set<String> = []
    /// Carpetas principales cuya rama, ramas o worktrees pueden haber cambiado.
    public private(set) var repositories: Set<String> = []

    public init() {}

    /// Anota los cambios. En los archivos de una carpeta, cambia su estado. En los datos de git de
    /// un repo, puede cambiar todo lo de ese repo: su rama, sus ramas, sus worktrees y el estado de
    /// cada carpeta.
    public mutating func record(_ changes: DirectoryChanges, in layout: GitLayout) {
        for repo in layout.repositories {
            if changes.all || !changes.roots.isDisjoint(with: repo.gitDirectories) {
                repositories.insert(repo.path)
                statuses.formUnion(repo.trees)
            } else {
                statuses.formUnion(repo.trees.filter(changes.roots.contains))
            }
        }
    }

    /// Se van a leer: dejan de contar como cambiados. Lo que cambie mientras tanto lo vuelve a anotar
    /// el próximo `record`.
    public mutating func clear(statuses dirs: some Sequence<String>, repositories repos: some Sequence<String>) {
        statuses.subtract(dirs)
        repositories.subtract(repos)
    }

    /// No se pudo leer o no se usó lo leído: se vuelve a leer en la próxima revisión.
    public mutating func markStatus(_ dir: String) {
        statuses.insert(dir)
    }

    public mutating func markRepository(_ path: String) {
        repositories.insert(path)
    }
}
