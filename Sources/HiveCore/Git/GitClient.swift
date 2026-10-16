import Foundation

/// Todo lo que Hive le pide a git. Es un protocolo para poder reemplazarlo en los tests.
/// Las llamadas bloquean: hacerlas fuera del hilo principal.
public protocol GitClient: Sendable {
    func topLevel(_ dir: String) -> String?
    /// Rama actual, o nil si HEAD está desacoplado o no es un repo. Durante un rebase, la rama que se rebasea.
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

    // Requisitos nuevos: tienen una implementación por defecto (abajo) para que los clientes
    // falsos de los tests sigan compilando.

    /// `git fetch` de todos los remotos. `timeout` nil usa el de red por defecto.
    func fetch(_ dir: String, timeout: TimeInterval?) -> CommandResult
    func pull(ffOnly: Bool, in dir: String) -> CommandResult
    /// Publica la rama en su remoto (origin si no tiene uno); `setUpstream` la deja siguiéndolo.
    func push(branch: String, setUpstream: Bool, in dir: String) -> CommandResult
    /// Últimos commits de `ref` (o de HEAD si es nil).
    func recentCommits(_ dir: String, ref: String?, limit: Int) -> [GitCommit]
    func resolveConflict(path: String, using resolution: ConflictResolution, in dir: String) -> CommandResult
    /// Carpeta principal del repo, aunque `dir` sea un worktree.
    func mainWorktree(_ dir: String) -> String?
    /// Cuáles de esas rutas (relativas a `dir`) ignora git. Los archivos con seguimiento nunca cuentan.
    func ignored(paths: [String], in dir: String) -> [String]
    /// Rama por defecto del remoto principal ("origin/main"), o nil si no hay remotos.
    func defaultRemoteBranch(_ dir: String) -> String?
    /// URL del remoto principal (origin, o el primero que haya).
    func remoteURL(_ dir: String) -> String?
    func remotes(_ dir: String) -> [String]
    /// Commit vacío (el primero de un repo nuevo, por ejemplo): no incluye lo que esté preparado.
    func commitAllowEmpty(message: String, in dir: String) -> CommandResult
    /// Como `addWorktree`, eligiendo el seguimiento de la rama nueva: true `--track`, false `--no-track`, nil lo que decida git.
    func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, track: Bool?, in dir: String) -> CommandResult
    /// Como `createBranch`, eligiendo el seguimiento (ver `addWorktree`).
    func createBranch(_ name: String, from base: String, track: Bool?, in dir: String) -> CommandResult
}

extension GitClient {
    private var unavailable: CommandResult { CommandResult(status: -1, stderr: "Esta operación de git no está disponible.") }

    public func fetch(_ dir: String, timeout: TimeInterval?) -> CommandResult { unavailable }
    public func fetch(_ dir: String) -> CommandResult { fetch(dir, timeout: nil) }
    public func pull(ffOnly: Bool, in dir: String) -> CommandResult { unavailable }
    public func push(branch: String, setUpstream: Bool, in dir: String) -> CommandResult { unavailable }
    public func recentCommits(_ dir: String, ref: String?, limit: Int) -> [GitCommit] {
        ref == nil ? recentCommits(dir, limit: limit) : []
    }
    public func resolveConflict(path: String, using resolution: ConflictResolution, in dir: String) -> CommandResult { unavailable }
    public func mainWorktree(_ dir: String) -> String? { worktrees(dir).first?.path }
    public func ignored(paths: [String], in dir: String) -> [String] { [] }
    public func defaultRemoteBranch(_ dir: String) -> String? { nil }
    public func remoteURL(_ dir: String) -> String? { nil }
    public func remotes(_ dir: String) -> [String] { [] }
    public func commitAllowEmpty(message: String, in dir: String) -> CommandResult { unavailable }
    public func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, track: Bool?, in dir: String) -> CommandResult {
        addWorktree(at: path, branch: branch, newBranch: newBranch, base: base, in: dir)
    }
    public func createBranch(_ name: String, from base: String, track: Bool?, in dir: String) -> CommandResult {
        createBranch(name, from: base, in: dir)
    }
}

/// Implementación con el git del sistema.
public struct GitCLI: GitClient {
    public let executable: String
    /// Límite de cada llamada (las colgadas vuelven con status -2).
    public let timeout: TimeInterval
    /// Límite de las que van por la red o escriben muchos archivos (fetch, pull, push, worktree add).
    public let networkTimeout: TimeInterval
    private let runner: CommandRunning
    private let environment = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]

    public init(executable: String = "/usr/bin/git", runner: CommandRunning = ProcessCommandRunner(),
                timeout: TimeInterval = 20, networkTimeout: TimeInterval = 120) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
        self.networkTimeout = networkTimeout
    }

    @discardableResult
    public func run(_ args: [String], in dir: String) -> CommandResult {
        run(args, in: dir, timeout: timeout)
    }

    /// `network`: sin preguntas por la terminal ni por ssh (si ssh necesita una clave con
    /// contraseña, falla con un mensaje en lugar de quedar colgado).
    @discardableResult
    public func run(_ args: [String], in dir: String, timeout limit: TimeInterval, network: Bool = false) -> CommandResult {
        var env = environment
        let inherited = ProcessInfo.processInfo.environment
        if network && inherited["GIT_SSH_COMMAND"] == nil && inherited["GIT_SSH"] == nil {
            // GIT_SSH_COMMAND le gana a core.sshCommand: se parte del que tenga el repo (una clave
            // propia con -i, por ejemplo) para no cambiar la cuenta con la que se conecta.
            let configured = run(["config", "--get", "core.sshCommand"], in: dir)
            env["GIT_SSH_COMMAND"] = Self.batchSSHCommand(configured: configured.ok ? configured.output : nil)
        }
        let r = runner.run(executable, ["-C", dir, "-c", "core.quotePath=false"] + args, cwd: nil, environment: env, timeout: limit)
        if r.timedOut {
            return CommandResult(status: r.status, stdout: r.stdout,
                                 stderr: "git tardó demasiado: se canceló después de \(String(format: "%g", limit)) s (git \(args.first ?? "")).")
        }
        return r
    }

    public func topLevel(_ dir: String) -> String? {
        guard FileManager.default.fileExists(atPath: dir) else { return nil }
        let r = run(["rev-parse", "--show-toplevel"], in: dir)
        return r.ok && !r.output.isEmpty ? r.output : nil
    }

    public func currentBranch(_ dir: String) -> String? {
        let r = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: dir)
        if r.ok && !r.output.isEmpty { return r.output }
        // Durante un rebase HEAD queda desacoplado: la rama está en rebase-merge/head-name.
        return rebasingBranch(dir)
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
        let r = run(["status", "--porcelain=v2", "-b", "-z"], in: dir)
        guard r.ok else { return nil }
        var status = GitParsing.statusV2(r.stdout)
        if let gitDir = gitDirectory(dir) {
            status.operation = GitParsing.operation(gitDir: gitDir, exists: { FileManager.default.fileExists(atPath: $0) })
            if status.branch == nil, status.operation == .rebase { status.branch = rebasingBranch(gitDir: gitDir) }
        }
        return status
    }

    public func recentCommits(_ dir: String, limit: Int = 8) -> [GitCommit] {
        recentCommits(dir, ref: nil, limit: limit)
    }

    public func recentCommits(_ dir: String, ref: String?, limit: Int) -> [GitCommit] {
        let r = run(["log", "-n", "\(limit)", "--format=%h%x1f%s%x1f%an%x1f%ct"] + (ref.map { [$0, "--"] } ?? []), in: dir)
        return r.ok ? GitParsing.commits(r.stdout) : []
    }

    public func diff(for change: GitChange, staged: Bool, in dir: String) -> FileDiff {
        if change.path.hasSuffix("/") {
            return FileDiff(message: "Carpeta nueva sin seguimiento. Abrila para ver su contenido.")
        }
        let args: [String]
        if change.isUntracked {
            args = ["diff", "--no-color", "--no-index", "--", "/dev/null", change.path]
        } else if let original = change.originalPath {
            // Renombre: con las dos rutas git lo reconoce y muestra solo lo que cambió adentro.
            args = ["diff", "--no-color", "-M"] + (staged ? ["--cached"] : []) + ["--", original, change.path]
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
        var diff = GitParsing.diff(r.stdout)
        if diff.lines.isEmpty && !diff.isBinary {
            if let original = change.originalPath {
                diff.message = "Se renombró desde «\(original)» sin cambios en el contenido."
            } else if change.isConflict {
                diff.message = "Archivo en conflicto: una de las ramas lo borró. Elegí qué versión usar."
            }
        }
        return diff
    }

    public func isValidBranchName(_ name: String, in dir: String) -> Bool {
        run(["check-ref-format", "--branch", name], in: dir).ok
    }

    public func initRepository(_ dir: String) -> CommandResult {
        run(["init"], in: dir)
    }

    public func createBranch(_ name: String, from base: String, in dir: String) -> CommandResult {
        createBranch(name, from: base, track: nil, in: dir)
    }

    public func createBranch(_ name: String, from base: String, track: Bool?, in dir: String) -> CommandResult {
        run(["branch"] + trackFlag(track) + [name, base], in: dir)
    }

    public func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, in dir: String) -> CommandResult {
        addWorktree(at: path, branch: branch, newBranch: newBranch, base: base, track: nil, in: dir)
    }

    public func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, track: Bool?, in dir: String) -> CommandResult {
        if newBranch {
            return run(["worktree", "add"] + trackFlag(track) + ["-b", branch, path] + (base.map { [$0] } ?? []),
                       in: dir, timeout: networkTimeout)
        }
        return run(["worktree", "add", path, branch], in: dir, timeout: networkTimeout)
    }

    public func removeWorktree(_ path: String, force: Bool, in dir: String) -> CommandResult {
        // Si la carpeta ya no existe (se borró por fuera), alcanza con olvidar esta entrada. Nunca con
        // `git worktree prune`: olvidaría también los worktrees de un disco desconectado, que quedarían rotos.
        if !FileManager.default.fileExists(atPath: path) {
            let listed = worktrees(dir)
            let entry = listed.first { samePath($0.path, path) }
            // Ya no está registrado: no hay nada que olvidar.
            if entry == nil && !listed.isEmpty { return CommandResult(status: 0) }
            let locked = entry?.isLocked == true
            if locked && !force {
                return CommandResult(status: 1, stderr: "La carpeta del worktree no está (¿un disco desconectado?) y está bloqueado con git worktree lock.")
            }
            // git acepta `worktree remove` con la carpeta faltante y toca solo esa entrada; bloqueado, con -f -f.
            return run(["worktree", "remove"] + (locked ? ["-f", "-f"] : []) + [entry?.path ?? path], in: dir)
        }
        var flags: [String] = []
        if force {
            // Un worktree bloqueado (`git worktree lock`) necesita el --force dos veces.
            let locked = worktrees(dir).contains { $0.isLocked && samePath($0.path, path) }
            flags = locked ? ["-f", "-f"] : ["--force"]
        }
        return run(["worktree", "remove"] + flags + [path], in: dir, timeout: networkTimeout)
    }

    public func checkout(_ branch: String, in dir: String) -> CommandResult {
        // `switch` nunca toca archivos: con `checkout docs` y una carpeta docs/, git no sabe qué querés.
        // Si la rama solo existe en un remoto, la crea siguiéndolo.
        run(["switch", branch], in: dir, timeout: networkTimeout)
    }

    public func fetch(_ dir: String, timeout limit: TimeInterval?) -> CommandResult {
        run(["fetch", "--all", "--prune", "--quiet"], in: dir, timeout: limit ?? networkTimeout, network: true)
    }

    public func pull(ffOnly: Bool, in dir: String) -> CommandResult {
        run(["pull", "--quiet"] + (ffOnly ? ["--ff-only"] : ["--no-rebase"]), in: dir, timeout: networkTimeout, network: true)
    }

    public func push(branch: String, setUpstream: Bool, in dir: String) -> CommandResult {
        let configured = run(["config", "--get", "branch.\(branch).remote"], in: dir).output
        guard let remote = configured.isEmpty || configured == "." ? primaryRemote(dir) : configured else {
            return CommandResult(status: -1, stderr: "El repo no tiene remotos.")
        }
        return run(["push", "--quiet"] + (setUpstream ? ["-u"] : []) + [remote, branch], in: dir, timeout: networkTimeout, network: true)
    }

    public func resolveConflict(path: String, using resolution: ConflictResolution, in dir: String) -> CommandResult {
        switch resolution {
        case .ours, .theirs:
            let side = resolution == .ours ? "--ours" : "--theirs"
            let picked = run(["checkout", side, "--", path], in: dir)
            if !picked.ok {
                // Esa versión no existe (ese lado borró el archivo): quedarse con ella es borrarlo.
                guard picked.errorMessage.contains("does not have") else { return picked }
                return run(["rm", "--quiet", "--", path], in: dir)
            }
            return run(["add", "-A", "--", path], in: dir)
        case .markResolved:
            return run(["add", "-A", "--", path], in: dir)
        }
    }

    public func mainWorktree(_ dir: String) -> String? {
        worktrees(dir).first?.path
    }

    public func ignored(paths: [String], in dir: String) -> [String] {
        var result: [String] = []
        // Las rutas van como argumentos, de a tandas, para no pasarnos del límite del sistema.
        var start = 0
        while start < paths.count {
            let chunk = Array(paths[start..<min(start + 200, paths.count)])
            start += 200
            // (-z solo va con --stdin, y el runner no tiene entrada: las rutas raras vienen entre comillas.)
            switch checkIgnore(chunk, in: dir) {
            case .found(let found):
                result += found
            case .failed where chunk.count > 1:
                // Una ruta mala no tiene que dejar afuera a las demás: de a una, salteando las que fallan.
                for path in chunk {
                    if case .found(let found) = checkIgnore([path], in: dir) { result += found }
                }
            case .failed, .timedOut:
                continue
            }
        }
        return result
    }

    public func defaultRemoteBranch(_ dir: String) -> String? {
        guard let remote = primaryRemote(dir) else { return nil }
        let head = run(["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"], in: dir)
        if head.ok && !head.output.isEmpty { return head.output }
        let known = Set(remoteBranches(dir))
        return ["main", "master", "develop", "trunk"].map { "\(remote)/\($0)" }.first(where: known.contains)
    }

    public func remoteURL(_ dir: String) -> String? {
        guard let remote = primaryRemote(dir) else { return nil }
        let r = run(["remote", "get-url", remote], in: dir)
        return r.ok && !r.output.isEmpty ? r.output : nil
    }

    public func remotes(_ dir: String) -> [String] {
        lines(run(["remote"], in: dir))
    }

    public func commitAllowEmpty(message: String, in dir: String) -> CommandResult {
        // --only sin rutas: el commit sale vacío aunque haya archivos preparados, que siguen preparados.
        run(["commit", "--quiet", "--allow-empty", "--only", "-m", message], in: dir)
    }

    // MARK: - Auxiliares

    /// GIT_SSH_COMMAND para las llamadas de red. Sin core.sshCommand, ssh con BatchMode; con uno que
    /// es ssh («ssh -i ~/.ssh/trabajo»), ese mismo más BatchMode; con otro programa, nil (se respeta tal cual).
    public static func batchSSHCommand(configured: String?) -> String? {
        let command = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { return "ssh -o BatchMode=yes" }
        let program = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard program == "ssh" || program.hasSuffix("/ssh") else { return nil }
        return command + " -o BatchMode=yes"
    }

    private enum CheckIgnoreResult { case found([String]), failed, timedOut }

    /// `git check-ignore` de una tanda. Falla entera si una ruta está adentro de un submódulo, por ejemplo.
    private func checkIgnore(_ paths: [String], in dir: String) -> CheckIgnoreResult {
        let r = run(["check-ignore", "--"] + paths, in: dir)
        // 0: alguno está ignorado; 1: ninguno; otro: error.
        switch r.status {
        case 0: return .found(r.stdout.split(separator: "\n").map { GitParsing.unquotePath(String($0)) }.filter { !$0.isEmpty })
        case 1: return .found([])
        default: return r.timedOut ? .timedOut : .failed
        }
    }

    /// origin si existe; si no, el primer remoto.
    private func primaryRemote(_ dir: String) -> String? {
        let all = remotes(dir)
        return all.contains("origin") ? "origin" : all.first
    }

    private func trackFlag(_ track: Bool?) -> [String] {
        switch track {
        case true?: ["--track"]
        case false?: ["--no-track"]
        case nil: []
        }
    }

    /// Carpeta de git de `dir`: `.git` si es una carpeta, lo que apunta si es un archivo (worktrees)
    /// y, si `dir` es una subcarpeta, lo que diga git.
    private func gitDirectory(_ dir: String) -> String? {
        let dotGit = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
            if isDir.boolValue { return dotGit }
            if let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
               let pointer = GitParsing.gitDirPointer(text, relativeTo: dir) { return pointer }
        }
        let r = run(["rev-parse", "--absolute-git-dir"], in: dir)
        return r.ok && !r.output.isEmpty ? r.output : nil
    }

    private func rebasingBranch(_ dir: String) -> String? {
        // Una carpeta que ya no existe no está en un rebase: sin otro proceso de git (load() lo llama
        // en el hilo principal para cada proyecto).
        guard FileManager.default.fileExists(atPath: dir), let gitDir = gitDirectory(dir) else { return nil }
        return rebasingBranch(gitDir: gitDir)
    }

    private func rebasingBranch(gitDir: String) -> String? {
        for folder in ["rebase-merge", "rebase-apply"] {
            let file = ((gitDir as NSString).appendingPathComponent(folder) as NSString).appendingPathComponent("head-name")
            if let text = try? String(contentsOfFile: file, encoding: .utf8), let name = GitParsing.rebaseHeadName(text) {
                return name
            }
        }
        return nil
    }

    private func lines(_ r: CommandResult) -> [String] {
        guard r.ok else { return [] }
        return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
