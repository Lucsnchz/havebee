import Foundation
@testable import HiveCore

/// Las carpetas temporales de una corrida de tests van todas dentro de una, con el pid del proceso:
/// se borra al salir, y al empezar se borran las de corridas que no llegaron a hacerlo (una que se
/// cortó). Antes quedaban miles sueltas: muchos stores siguen vivos hasta el final de la corrida, y
/// el deinit de su carpeta no llega a correr.
enum TestTemp {
    // realpath del sistema: /var → /private/var, igual que las rutas que devuelve git.
    // (resolvingSymlinksInPath de Foundation hace lo contrario y deja /var.)
    static let root: URL = {
        let base = URL(fileURLWithPath: TempDir.realPath(NSTemporaryDirectory()), isDirectory: true)
        removeAbandoned(in: base)
        let root = base.appendingPathComponent("\(prefix)\(getpid())", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestTemp.root) }
        return root
    }()

    private static let prefix = "hive-tests-"

    /// Las de corridas cuyo proceso ya no existe.
    private static func removeAbandoned(in base: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            guard let pid = pid_t(name.dropFirst(prefix.count)), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name, isDirectory: true))
        }
    }
}

/// Carpeta temporal que se borra sola (o con la de la corrida, ver `TestTemp`).
final class TempDir: @unchecked Sendable {
    let url: URL
    var path: String { url.path }

    init(_ name: String = "hive-test") {
        url = TestTemp.root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @discardableResult
    func write(_ relative: String, _ content: String = "") -> URL {
        let file = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func subdir(_ relative: String) -> URL {
        let dir = url.appendingPathComponent(relative, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }
}

/// Repo git real para pruebas de integración.
final class GitRepo: @unchecked Sendable {
    let dir: TempDir
    let path: String
    let git = GitCLI()

    init(branch: String = "main", name: String = "repo") {
        dir = TempDir("hive-git")
        path = dir.subdir(name).path
        sh("git init -q -b \(branch)")
        sh("git config user.email test@example.com && git config user.name Test && git config commit.gpgsign false")
        write("README.md", "# Repo\n")
        commit("Primer commit")
    }

    @discardableResult
    func sh(_ command: String, in cwd: String? = nil) -> CommandResult {
        ProcessCommandRunner().run("/bin/sh", ["-c", command], cwd: cwd ?? path,
                                   environment: ["GIT_AUTHOR_DATE": "2026-10-01T10:00:00", "GIT_COMMITTER_DATE": "2026-10-01T10:00:00"])
    }

    @discardableResult
    func write(_ relative: String, _ content: String) -> String {
        let file = (path as NSString).appendingPathComponent(relative)
        try! FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! content.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    func commit(_ message: String) {
        sh("git add -A && git commit -q -m \(shellQuote(message))")
    }

    /// Un remoto "origin" (bare) con la rama actual publicada.
    func addRemote() -> String {
        let remote = dir.subdir("remote.git").path
        sh("git init -q --bare \(shellQuote(remote))")
        sh("git remote add origin \(shellQuote(remote)) && git push -q -u origin HEAD 2>/dev/null")
        return remote
    }
}

extension Project {
    static func make(_ name: String = "demo", path: String = "/tmp/demo", branches: [Branch] = [Branch(name: "main", mode: .main)]) -> Project {
        Project(name: name, path: path, branches: branches)
    }
}

extension Date {
    static let reference = Date(timeIntervalSince1970: 1_790_000_000)
}
