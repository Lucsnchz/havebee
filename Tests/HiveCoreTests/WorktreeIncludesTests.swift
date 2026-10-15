import Foundation
import Testing
@testable import HiveCore

@Suite("Archivos que se copian a un worktree nuevo")
struct WorktreeIncludesTests {
    @Test("Patrones como en .gitignore: nivel, anclados, carpetas y negación", arguments: [
        (".env", [".env"], true),
        ("api/.env", [".env"], true),
        (".env.local", [".env.*"], true),
        (".env.example", [".env.*", "!.env.example"], false),
        (".claude/settings.local.json", [".claude/settings.local.json"], true),
        ("otro/.claude/settings.local.json", [".claude/settings.local.json"], false),
        ("app/release.jks", ["*.jks"], true),
        ("config/secretos/clave.txt", ["secretos/"], true),
        ("secretos", ["secretos/"], false),
        ("a/b/c/x.pem", ["**/x.pem"], true),
        ("x.pem", ["**/x.pem"], true),
        ("/raiz.txt", ["/raiz.txt"], true),
        ("sub/raiz.txt", ["/raiz.txt"], false),
        ("README.md", [".env"], false),
    ] as [(String, [String], Bool)])
    func patterns(path: String, patterns: [String], expected: Bool) {
        #expect(WorktreeIncludes.includes(path.hasPrefix("/") ? String(path.dropFirst()) : path, patterns: patterns) == expected)
    }

    @Test(".worktreeinclude manda; sin él, los de fábrica")
    func patternSource() {
        let dir = TempDir()
        #expect(WorktreeIncludes.patterns(root: dir.path) == WorktreeIncludes.defaultPatterns)
        dir.write(".worktreeinclude", "# comentario\n\n.env\n  storage/oauth-*.key  \n")
        #expect(WorktreeIncludes.patterns(root: dir.path) == [".env", "storage/oauth-*.key"])
    }

    @Test("Busca en el repo salteando node_modules, vendor, build y .git")
    func candidatesSkipHeavyFolders() {
        let dir = TempDir()
        dir.write(".env", "A=1")
        dir.write("node_modules/x/.env", "no")
        dir.write("vendor/y/.env", "no")
        dir.write("app/build/.env", "no")
        dir.write("api/.env.local", "B=2")
        dir.write(".claude/settings.local.json", "{}")
        dir.write("android/local.properties", "sdk.dir=/x")
        dir.write("README.md", "#")
        let found = WorktreeIncludes.candidates(root: dir.path, patterns: WorktreeIncludes.defaultPatterns)
        #expect(found == [".claude/settings.local.json", ".env", "android/local.properties", "api/.env.local"])
    }

    @Test("Repo real: copia solo lo ignorado (.env sí, .env.example con seguimiento no) y sin pisar")
    func onlyIgnoredAndNoOverwrite() throws {
        let repo = GitRepo()
        repo.write(".gitignore", ".env\nauth.json\n.claude/settings.local.json\n")
        repo.write(".env.example", "APP_URL=http://localhost\n")
        repo.commit("Ignorados")
        repo.write(".env", "APP_URL=https://repo.test\n")
        repo.write("auth.json", "{}")
        repo.write(".claude/settings.local.json", "{\"permissions\": {}}")
        let files = WorktreeIncludes.files(in: repo.path, git: repo.git)
        #expect(files == [".claude/settings.local.json", ".env", "auth.json"])

        let destination = repo.dir.subdir("destino").path
        try "ya estaba".write(toFile: destination + "/auth.json", atomically: true, encoding: .utf8)
        let copied = WorktreeIncludes.copy(files, from: repo.path, to: destination)
        #expect(copied == [".claude/settings.local.json", ".env"])
        #expect((try String(contentsOfFile: destination + "/auth.json", encoding: .utf8)) == "ya estaba")
        #expect((try String(contentsOfFile: destination + "/.env", encoding: .utf8)) == "APP_URL=https://repo.test\n")
        #expect(FileManager.default.fileExists(atPath: destination + "/.claude/settings.local.json"))
    }

    @Test("Con un sistema de archivos falso: lee, filtra y copia por la interfaz inyectada")
    func injectedFileSystem() {
        let disk = IncludesFakeDisk(files: ["/r/.env": "X=1", "/r/.worktreeinclude": ".env\n", "/r/notas.txt": "n"])
        let fs = disk.fileSystem
        #expect(WorktreeIncludes.patterns(root: "/r", fileSystem: fs) == [".env"])
        #expect(WorktreeIncludes.candidates(root: "/r", patterns: [".env"], fileSystem: fs) == [".env"])
        #expect(WorktreeIncludes.copy([".env", "falta.txt"], from: "/r", to: "/w", fileSystem: fs) == [".env"])
        #expect(disk.contents("/w/.env") == "X=1")
        // La segunda vez no pisa.
        #expect(WorktreeIncludes.copy([".env"], from: "/r", to: "/w", fileSystem: fs).isEmpty)
    }

    @Test("Resumen para el aviso")
    func summary() {
        #expect(WorktreeIncludes.summary([]) == "")
        #expect(WorktreeIncludes.summary([".env"]) == ".env")
        #expect(WorktreeIncludes.summary([".env", "auth.json"]) == ".env y auth.json")
        #expect(WorktreeIncludes.summary([".env", "auth.json", ".claude/settings.local.json"]) == ".env, auth.json y permisos de Claude")
        #expect(WorktreeIncludes.summary([".env", "auth.json", "a", "b"]) == ".env, auth.json y 2 más")
    }
}

/// Disco en memoria para WorktreeIncludes.
private final class IncludesFakeDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]

    init(files: [String: String]) { self.files = files }

    func contents(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return files[path]
    }

    var fileSystem: WorktreeIncludes.FileSystem {
        WorktreeIncludes.FileSystem(
            read: { [self] in contents($0) },
            files: { [self] root, _ in
                lock.lock()
                defer { lock.unlock() }
                return files.keys.filter { $0.hasPrefix(root + "/") }.map { String($0.dropFirst(root.count + 1)) }.sorted()
            },
            exists: { [self] in contents($0) != nil },
            copy: { [self] from, to in
                lock.lock()
                defer { lock.unlock() }
                guard let text = files[from] else { throw CocoaError(.fileNoSuchFile) }
                files[to] = text
            },
            write: { [self] text, path in
                lock.lock()
                files[path] = text
                lock.unlock()
            })
    }
}

@Suite("Rutas entre comillas de git")
struct GitUnquotePathTests {
    @Test("Saca comillas y escapes de C, incluido UTF-8 en octal", arguments: [
        ("simple.txt", "simple.txt"),
        (#""con \"comillas\".txt""#, #"con "comillas".txt"#),
        (#""barra\\invertida""#, #"barra\invertida"#),
        (#""tab\there""#, "tab\there"),
        (#""a\303\261o.md""#, "año.md"),
        (#""""#, ""),
    ])
    func unquote(raw: String, expected: String) {
        #expect(GitParsing.unquotePath(raw) == expected)
    }

    @Test("Repo real: check-ignore con nombres raros")
    func oddNames() {
        let repo = GitRepo()
        repo.write(".gitignore", "*.secreto\n")
        repo.commit("Ignorar")
        let names = ["con \"comillas\".secreto", "año.secreto", "normal.secreto", "visible.txt"]
        for name in names { repo.write(name, "x") }
        #expect(Set(repo.git.ignored(paths: names, in: repo.path)) == ["con \"comillas\".secreto", "año.secreto", "normal.secreto"])
        #expect(repo.git.ignored(paths: ["visible.txt"], in: repo.path).isEmpty)
    }
}
