import Foundation

/// Todo lo que Hive le pide a git. Es un protocolo para poder reemplazarlo en los tests.
/// Las llamadas bloquean: hacerlas fuera del hilo principal.
public protocol GitClient: Sendable {
    func topLevel(_ dir: String) -> String?
    /// Rama actual, o nil si HEAD está desacoplado o no es un repo.
    func currentBranch(_ dir: String) -> String?
    func localBranches(_ dir: String) -> [String]
    func remoteBranches(_ dir: String) -> [String]
    func worktrees(_ dir: String) -> [GitWorktree]
    func status(_ dir: String) -> GitStatus?
    func recentCommits(_ dir: String, limit: Int) -> [GitCommit]
    func diff(for change: GitChange, staged: Bool, in dir: String) -> FileDiff
    func isValidBranchName(_ name: String, in dir: String) -> Bool
    func initRepository(_ dir: String) -> CommandResult
    func createBranch(_ name: String, from base: String, in dir: String) -> CommandResult
    /// `newBranch`: crea la rama al mismo tiempo (`-b`) a partir de `base`.
    func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, in dir: String) -> CommandResult
    func removeWorktree(_ path: String, force: Bool, in dir: String) -> CommandResult
    func checkout(_ branch: String, in dir: String) -> CommandResult
}

/// Implementación con el git del sistema.
public struct GitCLI: GitClient {
    public let executable: String
    private let runner: CommandRunning
    private let environment = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]

    public init(executable: String = "/usr/bin/git", runner: CommandRunning = ProcessCommandRunner()) {
        self.executable = executable
        self.runner = runner
    }

    @discardableResult
    public func run(_ args: [String], in dir: String) -> CommandResult {
        runner.run(executable, ["-C", dir, "-c", "core.quotePath=false"] + args, cwd: nil, environment: environment)
    }

    public func topLevel(_ dir: String) -> String? {
        guard FileManager.default.fileExists(atPath: dir) else { return nil }
        let r = run(["rev-parse", "--show-toplevel"], in: dir)
        return r.ok && !r.output.isEmpty ? r.output : nil
    }

    public func currentBranch(_ dir: String) -> String? {
        let r = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: dir)
        return r.ok && !r.output.isEmpty ? r.output : nil
    }

    public func localBranches(_ dir: String) -> [String] {
        lines(run(["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"], in: dir))
    }

    public func remoteBranches(_ dir: String) -> [String] {
        lines(run(["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/remotes"], in: dir))
            .filter { $0.contains("/") && !$0.hasSuffix("/HEAD") }
    }

    public func worktrees(_ dir: String) -> [GitWorktree] {
        let r = run(["worktree", "list", "--porcelain"], in: dir)
        return r.ok ? GitParsing.worktrees(r.stdout) : []
    }

    public func status(_ dir: String) -> GitStatus? {
        guard FileManager.default.fileExists(atPath: dir) else { return nil }
        let r = run(["status", "--porcelain=v1", "-b"], in: dir)
        return r.ok ? GitParsing.status(r.stdout) : nil
    }

    public func recentCommits(_ dir: String, limit: Int = 8) -> [GitCommit] {
        let r = run(["log", "-n", "\(limit)", "--format=%h%x1f%s%x1f%an%x1f%ct"], in: dir)
        return r.ok ? GitParsing.commits(r.stdout) : []
    }

    public func diff(for change: GitChange, staged: Bool, in dir: String) -> FileDiff {
        if change.path.hasSuffix("/") {
            return FileDiff(message: "Carpeta nueva sin seguimiento. Abrila para ver su contenido.")
        }
        let args: [String]
        if change.isUntracked {
            args = ["diff", "--no-color", "--no-index", "--", "/dev/null", change.path]
        } else if staged {
            args = ["diff", "--no-color", "--cached", "--", change.path]
        } else {
            args = ["diff", "--no-color", "--", change.path]
        }
        // `--no-index` devuelve 1 cuando hay diferencias: no es un error.
        let r = run(args, in: dir)
        if !r.ok && r.stdout.isEmpty {
            return FileDiff(message: r.errorMessage.isEmpty ? "No se pudo leer el diff." : r.errorMessage)
        }
        return GitParsing.diff(r.stdout)
    }

    public func isValidBranchName(_ name: String, in dir: String) -> Bool {
        run(["check-ref-format", "--branch", name], in: dir).ok
    }

    public func initRepository(_ dir: String) -> CommandResult {
        run(["init"], in: dir)
    }

    public func createBranch(_ name: String, from base: String, in dir: String) -> CommandResult {
        run(["branch", name, base], in: dir)
    }

    public func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, in dir: String) -> CommandResult {
        if newBranch {
            return run(["worktree", "add", "-b", branch, path] + (base.map { [$0] } ?? []), in: dir)
        }
        return run(["worktree", "add", path, branch], in: dir)
    }

    public func removeWorktree(_ path: String, force: Bool, in dir: String) -> CommandResult {
        run(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: dir)
    }

    public func checkout(_ branch: String, in dir: String) -> CommandResult {
        run(["checkout", branch], in: dir)
    }

    private func lines(_ r: CommandResult) -> [String] {
        guard r.ok else { return [] }
        return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
