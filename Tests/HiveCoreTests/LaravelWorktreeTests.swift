import Foundation
import Testing
@testable import HiveCore

@Suite("Worktrees Laravel: preparación y configuración")
struct LaravelWorktreeTests {
    @Test("SQLite conserva su conexión al copiar .env a otro checkout", arguments: [nil, "database/local.sqlite"] as [String?])
    func sqliteConnection(database: String?) throws {
        let repo = GitRepo()
        repo.write("artisan", "<?php")
        repo.write("composer.json", "{}")
        repo.write(".gitignore", ".env\ndatabase/*.sqlite\n")
        repo.commit("Laravel")
        let original = "DB_CONNECTION=sqlite\n" + (database.map { "DB_DATABASE=\($0)\n" } ?? "")
        repo.write(".env", original)
        let db = repo.write(database ?? "database/database.sqlite", "base existente")
        let project = Project.make(path: repo.path)
        let result = try BranchPlanner.prepareDetailed(.init(projectId: project.id, name: "sqlite", isNew: true,
                         mode: .worktree, copyIgnored: true, automaticLaravelSetup: true), project: project, git: repo.git).get()
        let env = try String(contentsOfFile: try #require(result.branch.worktreePath) + "/.env", encoding: .utf8)
        #expect(EnvFile.value("DB_DATABASE", in: env) == db)
        #expect(try String(contentsOfFile: repo.path + "/.env", encoding: .utf8) == original)
        #expect(try String(contentsOfFile: db, encoding: .utf8) == "base existente")
    }

    @Test("Copia .env y MCP ignorados, conserva credenciales y usa la carpeta definitiva")
    func environmentAndFinalPath() throws {
        let repo = GitRepo(name: "tienda")
        repo.write("artisan", "<?php")
        repo.write("composer.json", #"{"require":{"laravel/framework":"^12.0"}}"#)
        repo.write(".gitignore", ".env\n.mcp.json\n")
        repo.commit("Laravel")
        repo.write(".env", "APP_URL=https://tienda.test\nAPP_KEY=base64:keep\nDB_DATABASE=tienda\nSESSION_DOMAIN=tienda.test\n")
        repo.write(".mcp.json", #"{"mcpServers":{"boost":{"command":"php","args":["artisan","boost:mcp"]}}}"#)
        let initial = GitParsing.worktreePath(for: "feature/checkout", projectPath: repo.path, style: .sibling)
        try FileManager.default.createDirectory(atPath: initial, withIntermediateDirectories: true)
        let project = Project.make(path: repo.path)
        let herd = HerdSites(parkedPaths: [(repo.path as NSString).deletingLastPathComponent], securedHosts: ["tienda.test"])
        let result = try BranchPlanner.prepareDetailed(.init(projectId: project.id, name: "feature/checkout", isNew: true,
                         mode: .worktree, location: .sibling, copyIgnored: true, automaticLaravelSetup: true, herd: herd),
                         project: project, git: repo.git).get()
        let path = try #require(result.branch.worktreePath)
        #expect(path != initial)
        let env = try String(contentsOfFile: path + "/.env", encoding: .utf8)
        #expect(EnvFile.value("APP_KEY", in: env) == "base64:keep")
        #expect(EnvFile.value("DB_DATABASE", in: env) == "tienda")
        #expect(EnvFile.value("APP_URL", in: env) == "https://\(try #require(result.branch.herdSite)).test")
        #expect(result.copiedFiles.contains(".mcp.json"))
        #expect(result.setupCommand?.contains("herd isolate") == true)
        #expect(result.setupCommand?.contains("migrate") == false)
        #expect(try String(contentsOfFile: repo.path + "/.env", encoding: .utf8).contains("APP_URL=https://tienda.test"))
    }

    @Test("Sin .env usa .env.example; sin Herd también se prepara Laravel")
    func exampleFallback() throws {
        let repo = GitRepo()
        repo.write("artisan", "<?php")
        repo.write("composer.json", "{}")
        repo.write(".env.example", "APP_KEY=\nDB_CONNECTION=sqlite\n")
        repo.commit("Laravel")
        let project = Project.make(path: repo.path)
        let result = try BranchPlanner.prepareDetailed(.init(projectId: project.id, name: "demo", isNew: true,
                         mode: .worktree, automaticLaravelSetup: true), project: project, git: repo.git).get()
        #expect(FileManager.default.fileExists(atPath: try #require(result.branch.worktreePath) + "/.env"))
        #expect(result.setupCommand?.contains("composer install --no-interaction") == true)
        #expect(result.setupCommand?.contains("herd ") == false)
    }

    @Test("Ejecuta en orden; un error de Composer o de Artisan corta la preparación", arguments: ["", "composer", "key:generate"])
    func executesAndStops(failure: String) throws {
        let dir = TempDir("laravel-setup")
        let root = dir.subdir("principal").path
        let tree = dir.subdir("worktree").path
        let bin = dir.subdir("bin").path
        dir.write("principal/package.json", #"{"scripts":{"build":"vite build"}}"#)
        dir.write("principal/package-lock.json", "{}")
        dir.write("worktree/.env", "APP_KEY=\n")
        let executable = """
        #!/bin/sh
        printf '%s %s\\n' "$(basename "$0")" "$*" >> "$TEST_LOG"
        if [ "$(basename "$0")" = composer ] && [ "$TEST_FAILURE" = composer ]; then exit 4; fi
        if [ "$1" = artisan ] && [ "$2" = "$TEST_FAILURE" ]; then exit 5; fi
        if [ "$1" = -r ]; then printf 1; fi
        """
        for name in ["composer", "php", "npm"] {
            let file = dir.write("bin/" + name, executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let plan = LaravelWorktreeSetup.make(projectPath: root, worktreePath: tree, herd: nil)
        let result = ProcessCommandRunner().run("/bin/zsh", ["-c", plan.command], cwd: tree,
                         environment: ["PATH": bin + ":/usr/bin:/bin", "TEST_LOG": dir.path + "/log", "TEST_FAILURE": failure])
        let log = try #require(dir.read("log"))
        if failure.isEmpty {
            #expect(result.ok, "\(result.errorMessage)")
            #expect(log.contains("php artisan key:generate --no-interaction"))
            #expect(log.contains("php artisan storage:link --no-interaction"))
            #expect(log.contains("npm ci\nnpm run build"))
        } else {
            #expect(!result.ok)
            #expect(!log.contains("npm "))
            if failure == "composer" { #expect(!log.contains("php ")) }
        }
        #expect(FileManager.default.fileExists(atPath: tree + "/storage/framework/views"))
    }

    @Test("Los nombres de Herd no pisan sitios existentes y conservan la versión de PHP")
    func herdCollisionAndPHP() {
        let herd = HerdSites(links: ["tienda-feature": "/otra", "tienda": "/tienda"], securedHosts: ["tienda.test"])
        let plan = LaravelWorktreeSetup.make(projectPath: "/tienda", worktreePath: "/tienda.worktrees/feature", herd: herd,
                                             exists: { _ in false })
        #expect(plan.site == "tienda-feature-2")
        #expect(plan.url == "https://tienda-feature-2.test")
        #expect(plan.command.contains("cd '/tienda' && herd which-php"))
        #expect(plan.command.contains("herd isolate \"$hive_php_version\" --site='tienda-feature-2'"))
        #expect(plan.command.contains("herd composer install"))
        #expect(!plan.command.contains("optimize:clear"))
    }

    @Test("MCP: rebasa solo rutas del repo y escribe una copia privada sin tocar el original")
    func scopedMCP() throws {
        let dir = TempDir()
        let root = dir.subdir("main").path
        let tree = dir.subdir("worktree").path
        let source = dir.write("main/.mcp.json", """
        {"mcpServers":{"boost":{"command":"php","args":["\(root)/artisan","boost:mcp"],"env":{"SITE_PATH":"\(root)","OTHER":"\(root)-other"}},
        "remote":{"url":"https://example.com/mcp","headers":{"Authorization":"secret"}}}}
        """)
        let before = try Data(contentsOf: source)
        let output = dir.url.appendingPathComponent("private-mcp/session.json")
        let result = MCPConfig.forWorktree(file: source, root: root, directory: tree, output: output)
        #expect(result.file == output)
        let boost = try #require(result.servers.first { $0.name == "boost" })
        #expect(boost.args == [tree + "/artisan", "boost:mcp"])
        #expect(boost.env["SITE_PATH"] == tree)
        #expect(boost.env["OTHER"] == root + "-other")
        #expect(try Data(contentsOf: source) == before)
        #expect((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int) == 0o600)
        let withHerd = MCPConfig.forWorktree(file: source, root: root, directory: tree, output: output, herdExecutable: "/Herd/bin/herd")
        let herdBoost = try #require(withHerd.servers.first { $0.name == "boost" })
        #expect(herdBoost.command == "/Herd/bin/herd")
        #expect(herdBoost.args == ["php", tree + "/artisan", "boost:mcp"])
    }

    @Test("Herd: link, versión PHP, TLS y Composer se ejecutan en el checkout correcto")
    func herdScript() throws {
        let dir = TempDir()
        let root = dir.subdir("principal").path
        let tree = dir.subdir("rama").path
        let bin = dir.subdir("bin").path
        dir.write("rama/.env", "APP_KEY=keep\n")
        let herd = """
        #!/bin/sh
        printf '%s | %s\\n' "$PWD" "$*" >> "$TEST_LOG"
        case "$1" in
          which-php) printf '%s\\n' "$TEST_BIN/php" ;;
          php) shift; exec "$TEST_BIN/php" "$@" ;;
        esac
        """
        let php = """
        #!/bin/sh
        if [ "$1" = -r ]; then
          case "$2" in *PHP_MAJOR_VERSION*) printf 8.3 ;; *) printf 0 ;; esac
        fi
        """
        for (name, text) in [("herd", herd), ("php", php)] {
            let file = dir.write("bin/" + name, text)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let sites = HerdSites(links: ["principal": root], securedHosts: ["principal.test"])
        let plan = LaravelWorktreeSetup.make(projectPath: root, worktreePath: tree, herd: sites, herdBinDirectory: bin)
        let result = ProcessCommandRunner().run("/bin/zsh", ["-c", plan.command], cwd: tree,
                         environment: ["TEST_BIN": bin, "TEST_LOG": dir.path + "/log"])
        #expect(result.ok, "\(result.errorMessage)")
        let log = try #require(dir.read("log"))
        #expect(log.contains("\(root) | which-php"))
        #expect(log.contains("\(tree) | link principal-rama"))
        #expect(log.contains("isolate 8.3 --site=principal-rama"))
        #expect(log.contains("secure principal-rama"))
        #expect(log.contains("composer install --no-interaction"))
        #expect(!log.contains("artisan key:generate"))
    }
}
