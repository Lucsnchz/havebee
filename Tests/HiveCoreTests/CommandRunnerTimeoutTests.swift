import Foundation
import Testing
@testable import HiveCore

@Suite("Procesos con límite de tiempo")
struct CommandRunnerTimeoutTests {
    let runner = ProcessCommandRunner()

    @Test("Un proceso colgado vuelve con status -2 al vencer el límite")
    func timesOut() {
        let start = Date()
        let r = runner.run("/bin/sleep", ["10"], cwd: nil, environment: [:], timeout: 0.3)
        #expect(r.status == -2)
        #expect(r.timedOut && !r.ok)
        #expect(r.stderr.contains("Tardó demasiado"))
        // Margen amplio: la máquina puede estar cargada, pero nunca espera los 10 s.
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test("Un nieto que hereda la salida no impide cortar a tiempo")
    func grandchildKeepsOutput() {
        let start = Date()
        let r = runner.run("/bin/sh", ["-c", "printf antes; (sleep 10) & wait"], cwd: nil, environment: [:], timeout: 0.3)
        #expect(r.timedOut)
        #expect(r.stdout == "antes")
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test("Con límite, un proceso rápido devuelve su salida normal")
    func fastProcess() {
        let r = runner.run("/bin/sh", ["-c", "printf hola; printf error >&2; exit 4"], cwd: nil, environment: [:], timeout: 10)
        #expect(r.status == 4 && r.stdout == "hola" && r.stderr == "error")
        #expect(!r.timedOut)
    }

    @Test("Un runner sin límite propio usa la versión de siempre")
    func defaultImplementation() {
        let fake = TimeoutFakeRunner()
        let r = fake.run("/bin/x", ["a"], cwd: nil, environment: [:], timeout: 1)
        #expect(r.stdout == "/bin/x a")
    }

    @Test("50 llamadas en paralelo terminan todas con su salida, con y sin límite")
    func concurrentCalls() {
        let results = TimeoutLockedResults()
        let done = DispatchSemaphore(value: 0)
        var threads: [Thread] = []
        for i in 0..<50 {
            let thread = Thread {
                let big = i % 5 == 0 ? "; head -c 300000 /dev/zero | tr '\\0' x >&2" : ""
                let command = "printf \(i)" + big
                let r = i % 2 == 0
                    ? ProcessCommandRunner().run("/bin/sh", ["-c", command], cwd: nil, environment: [:], timeout: 60)
                    : ProcessCommandRunner().run("/bin/sh", ["-c", command], cwd: nil, environment: [:])
                results.set(i, r)
                done.signal()
            }
            threads.append(thread)
        }
        threads.forEach { $0.start() }
        for _ in 0..<50 {
            #expect(done.wait(timeout: .now() + 120) == .success, "Una llamada quedó trabada")
        }
        let all = results.value
        #expect(all.count == 50)
        for (i, r) in all {
            #expect(r.ok && r.stdout == "\(i)")
            if i % 5 == 0 { #expect(r.stderr.count == 300_000) }
        }
    }

    @Test("git colgado: GitCLI corta y avisa que git tardó demasiado")
    func gitTimeout() throws {
        let dir = TempDir()
        let fakeGit = dir.write("git-colgado", "#!/bin/sh\nsleep 10\n").path
        #expect(chmod(fakeGit, 0o755) == 0)
        let git = GitCLI(executable: fakeGit, timeout: 0.3, networkTimeout: 0.3)
        let start = Date()
        let r = git.run(["status"], in: dir.path)
        #expect(r.status == -2)
        #expect(r.stderr.hasPrefix("git tardó demasiado"))
        #expect(git.status(dir.path) == nil)
        #expect(git.fetch(dir.path, timeout: 0.3).status == -2)
        #expect(Date().timeIntervalSince(start) < 20)
    }

    /// git falso que imprime GIT_SSH_COMMAND|GIT_TERMINAL_PROMPT y responde core.sshCommand con `sshCommand`.
    func environmentGit(_ dir: TempDir, name: String, sshCommand: String?) -> GitCLI {
        let config = sshCommand.map { "echo '\($0)'; exit 0" } ?? "exit 1"
        let script = """
        #!/bin/sh
        case "$*" in *"config --get core.sshCommand"*) \(config);; esac
        printf '%s|%s' "$GIT_SSH_COMMAND" "$GIT_TERMINAL_PROMPT"

        """
        let fakeGit = dir.write(name, script).path
        #expect(chmod(fakeGit, 0o755) == 0)
        return GitCLI(executable: fakeGit)
    }

    @Test("Las llamadas de red van sin preguntas: BatchMode de ssh y sin prompt de la terminal")
    func networkEnvironment() throws {
        let dir = TempDir()
        let git = environmentGit(dir, name: "git-entorno", sshCommand: nil)
        let fetched = git.fetch(dir.path)
        let env = ProcessInfo.processInfo.environment
        let inherited = env["GIT_SSH_COMMAND"]
        let keepsOwn = inherited != nil || env["GIT_SSH"] != nil
        #expect(fetched.stdout == "\(keepsOwn ? inherited ?? "" : "ssh -o BatchMode=yes")|0")
        // Las que no van por la red no tocan ssh.
        #expect(git.run(["status"], in: dir.path).stdout == "\(inherited ?? "")|0")
    }

    @Test("Con core.sshCommand (una clave propia) se usa ese mismo ssh, con BatchMode")
    func keepsConfiguredSSHCommand() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = TempDir()
        let git = environmentGit(dir, name: "git-clave", sshCommand: "ssh -i ~/.ssh/trabajo")
        if env["GIT_SSH_COMMAND"] == nil && env["GIT_SSH"] == nil {
            #expect(git.fetch(dir.path).stdout == "ssh -i ~/.ssh/trabajo -o BatchMode=yes|0")
            #expect(git.push(branch: "x", setUpstream: true, in: dir.path).stdout == "ssh -i ~/.ssh/trabajo -o BatchMode=yes|0")
        }
        // La decisión, sin procesos.
        #expect(GitCLI.batchSSHCommand(configured: nil) == "ssh -o BatchMode=yes")
        #expect(GitCLI.batchSSHCommand(configured: "  ") == "ssh -o BatchMode=yes")
        #expect(GitCLI.batchSSHCommand(configured: "ssh -i ~/.ssh/trabajo") == "ssh -i ~/.ssh/trabajo -o BatchMode=yes")
        #expect(GitCLI.batchSSHCommand(configured: "/usr/bin/ssh -p 2222") == "/usr/bin/ssh -p 2222 -o BatchMode=yes")
        // Otro programa (un envoltorio propio) se respeta tal cual: GIT_SSH_COMMAND no se pone.
        #expect(GitCLI.batchSSHCommand(configured: "/usr/local/bin/mi-ssh") == nil)
    }
}

/// Runner que solo implementa el requisito viejo.
private struct TimeoutFakeRunner: CommandRunning {
    func run(_ executable: String, _ args: [String], cwd: String?, environment: [String: String]) -> CommandResult {
        CommandResult(status: 0, stdout: ([executable] + args).joined(separator: " "))
    }
}

private final class TimeoutLockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int: CommandResult] = [:]

    func set(_ i: Int, _ r: CommandResult) {
        lock.lock()
        results[i] = r
        lock.unlock()
    }

    var value: [Int: CommandResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}
