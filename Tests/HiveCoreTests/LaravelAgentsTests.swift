import Foundation
import Testing
@testable import HiveCore

@Suite("Laravel con agentes: guías en los worktrees, base propia, Vite, comandos y «Preparar para agentes»")
struct LaravelAgentsTests {
    // MARK: - Guías y skills en el worktree

    @Test("Las guías y skills de Boost que git ignora se copian al worktree; el aviso agrupa las skills")
    func boostFilesReachWorktree() throws {
        let repo = GitRepo(name: "tienda")
        repo.write(".gitignore", ".env\n.claude/skills/\n.agents/skills/\nboost.json\nAGENTS.md\n")
        repo.write("CLAUDE.md", "# Guías versionadas")
        repo.commit("Laravel")
        repo.write(".env", "APP_KEY=base64:x\n")
        repo.write("AGENTS.md", "# Guías para Codex")
        repo.write("boost.json", #"{"agents":["claude_code"]}"#)
        repo.write(".claude/skills/laravel-best-practices/SKILL.md", "skill")
        repo.write(".claude/skills/pest-testing/SKILL.md", "skill")
        repo.write(".agents/skills/pest-testing/SKILL.md", "skill")
        let files = WorktreeIncludes.files(in: repo.path, git: repo.git)
        #expect(files.contains("AGENTS.md") && files.contains("boost.json"))
        #expect(files.contains(".claude/skills/pest-testing/SKILL.md"))
        // CLAUDE.md está en git: llega con el checkout, no se copia.
        #expect(!files.contains("CLAUDE.md"))
        #expect(WorktreeIncludes.summary([".env", ".claude/skills/a/SKILL.md", ".claude/skills/b/SKILL.md", "AGENTS.md"])
                == ".env, skills de Claude y AGENTS.md")
    }

    // MARK: - Base propia

    @Test("MySQL: nombre de la copia según la carpeta, solo en esta Mac y con nombres seguros")
    func mysqlPlan() {
        let env = "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_DATABASE=tienda\nDB_PASSWORD=secreto\n"
        let sibling = WorktreeDatabase.plan(env: env, projectPath: "/Herd/tienda", worktreePath: "/Herd/tienda-feature-checkout")
        #expect(sibling == WorktreeDatabase(kind: .mysql, source: "tienda", target: "tienda_feature_checkout"))
        #expect(sibling?.stored == "mysql:tienda_feature_checkout")
        let nested = WorktreeDatabase.plan(env: env, projectPath: "/Herd/tienda", worktreePath: "/Herd/tienda.worktrees/fix-pagos")
        #expect(nested?.target == "tienda_fix_pagos")
        #expect(WorktreeDatabase.plan(env: env.replacingOccurrences(of: "127.0.0.1", with: "db.empresa.com"),
                                      projectPath: "/t", worktreePath: "/t-x") == nil)
        #expect(WorktreeDatabase.plan(env: "DB_CONNECTION=pgsql\nDB_DATABASE=tienda\n", projectPath: "/t", worktreePath: "/t-x") == nil)
        #expect(WorktreeDatabase.plan(env: "DB_CONNECTION=mysql\nDB_DATABASE=tienda`; DROP\n", projectPath: "/t", worktreePath: "/t-x") == nil)
        #expect(WorktreeDatabase.plan(env: env + "DB_URL=mysql://x\n", projectPath: "/t", worktreePath: "/t-x") == nil)
        let long = WorktreeDatabase.plan(env: env, projectPath: "/t", worktreePath: "/t-" + String(repeating: "rama", count: 30))
        #expect((long?.target.count ?? 0) <= 64)
        #expect(WorktreeDatabase.mysqlName(stored: "mysql:tienda_x") == "tienda_x")
        #expect(WorktreeDatabase.mysqlName(stored: "mysql:a`b") == nil)
    }

    @Test("MySQL: el worktree apunta a su copia, la preparación la crea y la contraseña nunca va en el comando")
    func mysqlBranch() throws {
        let repo = GitRepo(name: "tienda")
        repo.write("artisan", "<?php")
        repo.write("composer.json", #"{"require":{"laravel/framework":"^13.0"}}"#)
        repo.write(".gitignore", ".env\n")
        repo.commit("Laravel")
        repo.write(".env", "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_DATABASE=tienda\nDB_USERNAME=root\nDB_PASSWORD=s3cr3t\n")
        let project = Project.make(path: repo.path)
        let result = try BranchPlanner.prepareDetailed(.init(projectId: project.id, name: "checkout", isNew: true, mode: .worktree,
                         location: .sibling, copyIgnored: true, automaticLaravelSetup: true, ownDatabase: true),
                         project: project, git: repo.git).get()
        let path = try #require(result.branch.worktreePath)
        let env = try String(contentsOfFile: path + "/.env", encoding: .utf8)
        let target = "tienda_" + (path as NSString).lastPathComponent.dropFirst("tienda-".count).lowercased()
        #expect(EnvFile.value("DB_DATABASE", in: env) == target)
        #expect(result.branch.ownDatabase == "mysql:\(target)")
        let setup = try #require(result.setupCommand)
        #expect(setup.contains("CREATE DATABASE `\(target)`"))
        #expect(!setup.contains("s3cr3t"))
        #expect(try String(contentsOfFile: repo.path + "/.env", encoding: .utf8).contains("DB_DATABASE=tienda\n"))

        // Sin pedirla, la rama usa la misma base que el principal.
        let shared = try BranchPlanner.prepareDetailed(.init(projectId: project.id, name: "otra", isNew: true, mode: .worktree,
                         location: .sibling, copyIgnored: true, automaticLaravelSetup: true),
                         project: project, git: repo.git).get()
        let sharedEnv = try String(contentsOfFile: try #require(shared.branch.worktreePath) + "/.env", encoding: .utf8)
        #expect(EnvFile.value("DB_DATABASE", in: sharedEnv) == "tienda")
        #expect(shared.branch.ownDatabase == nil)
    }

    @Test("MySQL: la copia pasa la contraseña por el entorno y no pisa una base que ya existe", arguments: [false, true])
    func mysqlStepsRun(alreadyExists: Bool) throws {
        let dir = TempDir()
        let bin = dir.subdir("bin").path
        let log = dir.path + "/log"
        let fake = """
        #!/bin/sh
        printf '%s|%s|%s\\n' "$(basename "$0")" "$MYSQL_PWD" "$*" >> "\(log)"
        case "$(basename "$0")" in
          php) printf "hive_db_host='127.0.0.1'\\nhive_db_port='3307'\\nhive_db_username='root'\\nhive_db_password='s3 cr3t'\\n" ;;
          mysqldump) printf -- '-- dump\\n' ;;
          mysql) case "$*" in
                   *information_schema*) if [ "$TEST_EXISTS" = 1 ]; then printf 'tienda_checkout\\n'; fi ;;
                   *" tienda_checkout") cat >/dev/null ;;
                 esac ;;
        esac
        exit 0
        """
        for name in ["php", "mysql", "mysqldump"] {
            let file = dir.write("bin/" + name, fake)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let database = WorktreeDatabase(kind: .mysql, source: "tienda", target: "tienda_checkout")
        let script = (["set -e"] + database.steps(php: "php")).joined(separator: "\n")
        let result = ProcessCommandRunner().run("/bin/zsh", ["-c", script], cwd: dir.path,
                         environment: ["PATH": bin + ":/usr/bin:/bin", "TEST_EXISTS": alreadyExists ? "1" : "0"])
        #expect(result.ok, "\(result.errorMessage)")
        let calls = try #require(dir.read("log")).split(separator: "\n").map(String.init)
        let mysqlCalls = calls.filter { !$0.hasPrefix("php|") }
        #expect(mysqlCalls.allSatisfy { $0.contains("|s3 cr3t|--protocol=TCP -h 127.0.0.1 -P 3307 -u root") })
        if alreadyExists {
            #expect(!calls.contains { $0.contains("CREATE DATABASE") || $0.hasPrefix("mysqldump") })
            #expect(result.output.contains("ya existe"))
        } else {
            let order = mysqlCalls.map { $0.hasPrefix("mysqldump") ? "dump" : $0.contains("CREATE DATABASE `tienda_checkout`") ? "create"
                : $0.hasSuffix(" tienda_checkout") ? "import" : "check" }
            #expect(order == ["check", "dump", "create", "import"])
        }
    }

    @Test("SQLite: copia la base del principal a la carpeta de la rama y no la pisa al reintentar")
    func sqliteCopyRuns() throws {
        let dir = TempDir()
        let root = dir.subdir("tienda").path
        let tree = dir.subdir("tienda-checkout").path
        let source = root + "/database/database.sqlite"
        try FileManager.default.createDirectory(atPath: root + "/database", withIntermediateDirectories: true)
        let sqlite = ProcessCommandRunner()
        #expect(sqlite.run("/usr/bin/sqlite3", [source, "CREATE TABLE productos (nombre TEXT); INSERT INTO productos VALUES ('mate');"]).ok)
        let database = try #require(WorktreeDatabase.plan(env: "DB_CONNECTION=sqlite\n", projectPath: root, worktreePath: tree))
        #expect(database.target == tree + "/database/database.sqlite")
        #expect(database.label(worktreePath: tree) == "database/database.sqlite")
        let script = (["set -e"] + database.steps(php: "php")).joined(separator: "\n")
        #expect(sqlite.run("/bin/zsh", ["-c", script], cwd: tree, environment: ["PATH": "/usr/bin:/bin"]).ok)
        #expect(sqlite.run("/usr/bin/sqlite3", [database.target, "SELECT nombre FROM productos;"]).output.contains("mate"))
        // La rama cambia su copia; reintentar la preparación no la vuelve a pisar.
        #expect(sqlite.run("/usr/bin/sqlite3", [database.target, "INSERT INTO productos VALUES ('yerba');"]).ok)
        #expect(sqlite.run("/bin/zsh", ["-c", script], cwd: tree, environment: ["PATH": "/usr/bin:/bin"]).ok)
        #expect(sqlite.run("/usr/bin/sqlite3", [database.target, "SELECT count(*) FROM productos;"]).output.contains("2"))
        #expect(sqlite.run("/usr/bin/sqlite3", [source, "SELECT count(*) FROM productos;"]).output.contains("1"))
    }

    // MARK: - Vite con HTTPS

    @Test("Con HTTPS, el .env del worktree apunta Vite al certificado de su sitio en Herd")
    func viteCertificate() {
        let secured = HerdSites(links: ["tienda": "/tienda"], securedHosts: ["tienda.test"], certificatesDirectory: "/Herd/Certificates")
        let plan = LaravelWorktreeSetup.make(projectPath: "/tienda", worktreePath: "/tienda.worktrees/checkout", herd: secured,
                                             exists: { _ in false })
        #expect(plan.site == "tienda-checkout")
        #expect(plan.env["VITE_DEV_SERVER_KEY"] == "/Herd/Certificates/tienda-checkout.test.key")
        #expect(plan.env["VITE_DEV_SERVER_CERT"] == "/Herd/Certificates/tienda-checkout.test.crt")
        let insecure = LaravelWorktreeSetup.make(projectPath: "/tienda", worktreePath: "/tienda.worktrees/checkout",
                                                 herd: HerdSites(links: ["tienda": "/tienda"]), exists: { _ in false })
        #expect(insecure.env["VITE_DEV_SERVER_KEY"] == nil)
    }

    // MARK: - Comandos con Herd

    private func laravel(_ dir: TempDir, pest: String? = "v5.3.3", devScript: Bool = true) {
        dir.write("artisan")
        dir.write("composer.json", """
        {"require": {"laravel/framework": "^13.0"}, "require-dev": {"laravel/pail": "^1.2", "laravel/pint": "^1.27", "pestphp/pest": "^5.0"},
         "scripts": {"dev": ["Composer\\\\Config::disableProcessTimeout", "npx concurrently \\"php artisan serve\\" \\"php artisan queue:listen --tries=1\\" \\"npm run dev\\""]}}
        """)
        if let pest { dir.write("composer.lock", #"{"packages": [], "packages-dev": [{"name": "pestphp/pest", "version": "\#(pest)"}]}"#) }
        dir.write("package.json", devScript ? #"{"scripts": {"dev": "vite", "build": "vite build"}, "devDependencies": {"concurrently": "^9", "vite": "^7"}}"# : "{}")
    }

    @Test("Si Herd sirve el proyecto: sin artisan serve, Vite, tests afectados con Xdebug de Herd, Pint y dev sin servidor")
    func herdCommands() throws {
        let dir = TempDir()
        laravel(dir)
        // Herd sirve la carpeta (un `herd link`): el sitio ya está en <nombre>.test.
        let herd = HerdSites(links: ["tienda": dir.path])
        let suggestions = CommandSuggestions.detect(projectPath: dir.path, herd: herd)
        let commands = suggestions.map(\.command)
        #expect(!commands.contains("php artisan serve"))
        #expect(!commands.contains("composer run dev"))
        #expect(suggestions.first { $0.command == "npm run dev" }?.name == "Vite")
        #expect(commands.contains("herd coverage vendor/bin/pest --tia"))
        #expect(commands.contains("vendor/bin/pint --dirty"))
        let dev = try #require(suggestions.first { $0.name == "Dev con Herd" })
        #expect(dev.command == ##"npx concurrently -c "#c4b5fd,#fb7185,#fdba74" "php artisan queue:listen --tries=1" "php artisan pail --timeout=0" "npm run dev" --names=queue,logs,vite --kill-others"##)

        // Sin Herd: el servidor de Laravel, composer run dev y TIA con el driver que tengas.
        let plain = CommandSuggestions.detect(projectPath: dir.path).map(\.command)
        #expect(plain.contains("php artisan serve") && plain.contains("composer run dev"))
        #expect(plain.contains("vendor/bin/pest --tia"))
    }

    @Test("Los tests afectados son de Pest 5: con Pest 4 o sin composer.lock no se sugieren", arguments: ["v4.7.8", nil] as [String?])
    func tiaNeedsPest5(pest: String?) {
        let dir = TempDir()
        laravel(dir, pest: pest)
        #expect(!CommandSuggestions.detect(projectPath: dir.path).contains { $0.command.contains("--tia") })
    }

    // MARK: - Preparar para agentes

    private func kit(_ dir: TempDir, servers: [MCPServer] = [], commands: [ProjectCommand] = [], herd: Bool = false, home: TempDir = TempDir()) -> LaravelAgentKit? {
        LaravelAgentKit.inspect(projectPath: dir.path, home: home.url, servers: servers, commands: commands, herdInstalled: herd)
    }

    @Test("Proyecto sin Boost ni PAO: los instala juntos y boost:install pregunta en la terminal")
    func freshProject() throws {
        let dir = TempDir()
        dir.write("artisan")
        dir.write("composer.json", #"{"require": {"laravel/framework": "^13.0"}}"#)
        let kit = try #require(self.kit(dir))
        #expect(kit.pending.map(\.step) == [.boost, .pao])
        let script = try #require(kit.script([.boost, .pao]))
        #expect(script.contains("composer require laravel/boost laravel/pao --dev --no-interaction\nphp artisan boost:install"))
        #expect(kit.script([]) == nil)
        #expect(LaravelAgentKit.inspect(projectPath: TempDir().path, home: TempDir().url, servers: [], commands: [], herdInstalled: false) == nil)
    }

    @Test("Con Boost: avisa si composer.lock es más nuevo que las guías y suma boost:update a composer update")
    func boostUpToDate() throws {
        let dir = TempDir()
        dir.write("artisan")
        dir.write("composer.json", #"{"require-dev": {"laravel/boost": "^2.10", "laravel/pao": "^1.1"}, "scripts": {"post-update-cmd": ["@php artisan vendor:publish --tag=laravel-assets --ansi --force"]}}"#)
        let guides = dir.write("CLAUDE.md", "# Guías")
        let lock = dir.write("composer.lock", "{}")
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: guides.path)
        var kit = try #require(self.kit(dir))
        #expect(kit.pending.map(\.step) == [.guidelines, .autoUpdate])
        let script = try #require(kit.script([.guidelines, .autoUpdate]))
        #expect(script.contains("php artisan boost:update\n"))
        #expect(script.contains("@php artisan boost:update --ansi"))

        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lock.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: guides.path)
        dir.write("composer.json", #"{"require-dev": {"laravel/boost": "^2.10", "laravel/pao": "^1.1"}, "scripts": {"post-update-cmd": "@php artisan boost:update --ansi"}}"#)
        kit = try #require(self.kit(dir))
        #expect(kit.pending.isEmpty)
    }

    @Test("Nightwatch por npx mcp-remote se cambia a conexión directa; Herd y los tests afectados se suman")
    func mcpAndCommands() throws {
        let dir = TempDir()
        let home = TempDir()
        home.write("Library/Application Support/Herd/bin/herd-mcp.phar")
        dir.write("artisan")
        dir.write("composer.json", #"{"require": {"laravel/nightwatch": "^1.21"}, "require-dev": {"laravel/boost": "^2", "laravel/pao": "^1"}}"#)
        dir.write("composer.lock", #"{"packages-dev": [{"name": "pestphp/pest", "version": "v5.3.4"}]}"#)
        let old = MCPServer(name: "nightwatch", config: ["command": "npx", "args": ["-y", "mcp-remote", "https://nightwatch.laravel.com/mcp"]])
        let kit = try #require(self.kit(dir, servers: [old], herd: true, home: home))
        #expect(Set(kit.pending.map(\.step)).isSuperset(of: [.nightwatch, .herd, .fastTests]))
        #expect(kit.fastTestsCommand == "herd coverage vendor/bin/pest --tia")
        let changes = kit.servers([.nightwatch, .herd])
        #expect(changes.map(\.server.name) == ["nightwatch", "herd"])
        #expect(changes[0].replacing == "nightwatch")
        #expect(changes[0].server.url == "https://nightwatch.laravel.com/mcp")
        #expect(changes[1].server.env["SITE_PATH"] == dir.path)

        let ready = try #require(self.kit(dir, servers: [MCPServer(name: "nightwatch", config: ["type": "http", "url": "https://nightwatch.laravel.com/mcp"]),
                                                         MCPServer(name: "herd", config: ["command": "php"])],
                                          commands: [ProjectCommand(name: "TIA", command: "herd coverage vendor/bin/pest --tia")],
                                          herd: true, home: home))
        #expect(!ready.pending.contains { [.nightwatch, .herd, .fastTests].contains($0.step) })
        #expect(ready.servers([.nightwatch, .herd]).isEmpty)
    }
}
