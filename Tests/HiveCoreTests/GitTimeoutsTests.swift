import Foundation
import Testing
@testable import HiveCore

@Suite("Límites de tiempo de git por tipo de operación, y cancelar")
struct GitTimeoutsTests {
    @Test("Cada llamada tiene su tipo: local, red, mucho archivo o hooks")
    func callKinds() {
        #expect(GitCallKind.of(["status", "--porcelain=v2"]) == .local)
        #expect(GitCallKind.of(["config", "--get", "core.sshCommand"]) == .local)
        #expect(GitCallKind.of(["add", "-A", "--", "a.txt"]) == .local)
        #expect(GitCallKind.of(["branch", "x", "main"]) == .local)
        #expect(GitCallKind.of(["fetch", "--all"]) == .network)
        #expect(GitCallKind.of(["push", "--quiet", "origin", "x"]) == .hooks)
        #expect(GitCallKind.of(["pull", "--ff-only"]) == .hooks)
        #expect(GitCallKind.of(["switch", "feat"]) == .hooks)
        #expect(GitCallKind.of(["commit", "-m", "x"]) == .hooks)
        #expect(GitCallKind.of(["worktree", "add", "-b", "x", "/w"]) == .hooks)
        #expect(GitCallKind.of(["worktree", "remove", "/w"]) == .bulk)
        #expect(GitCallKind.of(["worktree", "list", "--porcelain"]) == .local)
        // checkout de una rama corre post-checkout; el de un archivo en conflicto, no.
        #expect(GitCallKind.of(["checkout", "feat"]) == .hooks)
        #expect(GitCallKind.of(["checkout", "--ours", "--", "a.txt"]) == .local)
        #expect(GitCallKind.of([]) == .local)
    }

    @Test("Las que corren hooks tienen mucho más margen, y nunca menos que las de red")
    func limits() {
        let standard = GitTimeouts.standard
        #expect(standard.limit(for: .local) == 20)
        #expect(standard.limit(for: .network) == 120)
        #expect(standard.limit(for: .bulk) == 120)
        #expect(standard.limit(for: .hooks) >= 15 * 60)
        #expect(GitTimeouts(local: 1, network: 50, hooks: 10).limit(for: .hooks) == 50)
    }

    @Test("GitCLI le pasa a cada operación el límite que le corresponde")
    func cliUsesLimitPerOperation() {
        let runner = GitTimeoutsRecordingRunner()
        let git = GitCLI(executable: "/fake/git", runner: runner, timeout: 1, networkTimeout: 2, hooksTimeout: 3)
        let dir = TempDir()
        func limit(_ subcommand: String, _ call: () -> Void) -> [TimeInterval] {
            runner.reset()
            call()
            return runner.calls.filter { $0.args.first == subcommand }.map(\.timeout)
        }
        #expect(limit("push") { _ = git.push(branch: "x", setUpstream: true, in: dir.path) } == [3])
        #expect(limit("pull") { _ = git.pull(ffOnly: true, in: dir.path) } == [3])
        #expect(limit("switch") { _ = git.checkout("feat", in: dir.path) } == [3])
        #expect(limit("worktree") { _ = git.addWorktree(at: "/w", branch: "x", newBranch: true, base: "main", in: dir.path) } == [3])
        #expect(limit("worktree") { _ = git.addWorktree(at: "/w", branch: "x", newBranch: false, base: nil, in: dir.path) } == [3])
        #expect(limit("commit") { _ = git.commitAllowEmpty(message: "Primer commit", in: dir.path) } == [3])
        #expect(limit("worktree") { _ = git.removeWorktree(dir.path, force: false, in: dir.path) } == [2])
        #expect(limit("fetch") { _ = git.fetch(dir.path) } == [2])
        #expect(limit("fetch") { _ = git.fetch(dir.path, timeout: 10) } == [10])
        #expect(limit("status") { _ = git.status(dir.path) } == [1])
        #expect(limit("checkout") { _ = git.resolveConflict(path: "a.txt", using: .ours, in: dir.path) } == [1])
        // Las previas al push (qué remoto usar) son locales.
        runner.reset()
        _ = git.push(branch: "x", setUpstream: true, in: dir.path)
        #expect(runner.calls.filter { $0.args.first == "config" || $0.args.first == "remote" }.allSatisfy { $0.timeout == 1 })
    }

    @Test("Un checkout que tarda más que el límite local (un post-checkout lento) no se corta")
    func slowHookIsNotKilled() throws {
        let dir = TempDir()
        let fakeGit = dir.write("git-hook-lento", "#!/bin/sh\nsleep 1\nprintf listo\n").path
        #expect(chmod(fakeGit, 0o755) == 0)
        let git = GitCLI(executable: fakeGit, timeout: 0.3, networkTimeout: 0.3, hooksTimeout: 30)
        let checkout = git.checkout("feat", in: dir.path)
        #expect(checkout.ok, "\(checkout.errorMessage)")
        #expect(checkout.stdout == "listo")
        // Lo local sigue cortándose a tiempo.
        #expect(git.run(["status"], in: dir.path).timedOut)
    }

    @Test("CancellableWork: cancelar corta el proceso y lo que lanzó")
    func cancelKillsProcess() async throws {
        let dir = TempDir()
        let pidFile = dir.path + "/nieto.pid"
        let start = Date()
        let task = Task {
            await CancellableWork.run {
                ProcessCommandRunner().run("/bin/sh", ["-c", "sleep 30 & echo $! > \(shellQuote(pidFile)); wait"],
                                           cwd: nil, environment: [:], timeout: 60)
            }
        }
        // Se cancela con el proceso ya corriendo (margen amplio: la máquina puede estar cargada).
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: pidFile) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let cancelledAt = Date()
        task.cancel()
        let result = await task.value
        #expect(result.cancelled && !result.ok)
        #expect(Date().timeIntervalSince(cancelledAt) < 10)
        #expect(Date().timeIntervalSince(start) < 30)
        #expect(try GitTimeoutsTests.waitUntilGone(pidFile), "El nieto quedó vivo")
    }

    @Test("CancellableWork sin límite de tiempo también se puede cancelar")
    func cancelWithoutTimeout() async throws {
        let start = Date()
        let task = Task { await CancellableWork.run { ProcessCommandRunner().run("/bin/sleep", ["30"]) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        #expect(await task.value.cancelled)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test("Fuera de CancellableWork, cancelar la tarea no corta el proceso (una revisión de git a medias sería un error)")
    func plainTasksAreNotCancelled() async {
        let task = Task.detached {
            ProcessCommandRunner().run("/bin/sh", ["-c", "sleep 0.5; printf ok"], cwd: nil, environment: [:], timeout: 30)
        }
        task.cancel()
        let result = await task.value
        #expect(result.ok && result.stdout == "ok")
    }

    @Test("Cancelar un push de GitCLI vuelve con «Cancelaste git push.»")
    func cancelPush() async throws {
        let dir = TempDir()
        let started = dir.path + "/push-empezo"
        // Como un pre-push que corre la suite de tests: avisa que empezó y tarda.
        let script = """
        #!/bin/sh
        case "$*" in *"config --get"*) exit 1;; *" remote") echo origin; exit 0;; esac
        touch \(shellQuote(started))
        sleep 30

        """
        let fakeGit = dir.write("git-push-lento", script).path
        #expect(chmod(fakeGit, 0o755) == 0)
        let git = GitCLI(executable: fakeGit)
        let path = dir.path
        let task = Task { await CancellableWork.run { git.push(branch: "x", setUpstream: true, in: path) } }
        // Se cancela con el push ya en marcha (la máquina puede estar cargada: margen amplio).
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: started) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: started))
        task.cancel()
        let result = await task.value
        #expect(result.cancelled)
        #expect(result.stderr == "Cancelaste git push.")
    }

    /// Espera (con margen, la máquina puede estar cargada) a que un proceso ya no exista.
    static func waitUntilGone(_ pidFile: String) throws -> Bool {
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while text.isEmpty && Date() < deadline {
            text = (try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { usleep(50_000) }
        }
        let pid = try #require(pid_t(text))
        while kill(pid, 0) == 0 && Date() < deadline { usleep(50_000) }
        return kill(pid, 0) != 0
    }
}

/// Runner que registra qué límite recibe cada llamada a git. Responde como un repo con «origin».
private final class GitTimeoutsRecordingRunner: CommandRunning, @unchecked Sendable {
    struct Call { let args: [String]; let timeout: TimeInterval }
    private let lock = NSLock()
    private var recorded: [Call] = []

    var calls: [Call] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded = [] } }

    func run(_ executable: String, _ args: [String], cwd: String?, environment: [String: String]) -> CommandResult {
        run(executable, args, cwd: cwd, environment: environment, timeout: .infinity)
    }

    func run(_ executable: String, _ args: [String], cwd: String?, environment: [String: String], timeout: TimeInterval) -> CommandResult {
        // Sin los globales: -C <carpeta> -c core.quotePath=false.
        let gitArgs = Array(args.dropFirst(4))
        lock.withLock { recorded.append(Call(args: gitArgs, timeout: timeout)) }
        switch gitArgs.first {
        case "config": return CommandResult(status: 1)
        case "remote": return CommandResult(status: 0, stdout: "origin\n")
        default: return CommandResult(status: 0)
        }
    }
}
