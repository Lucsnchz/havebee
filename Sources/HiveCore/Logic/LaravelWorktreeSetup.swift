import Foundation

/// La preparación se genera otra vez con la carpeta que git realmente creó, no con la vista previa.
public struct LaravelWorktreeSetup: Equatable, Sendable {
    public var command: String
    public var site: String?
    public var url: String?
    /// Valores para el .env del worktree: la base propia y el certificado de Herd para Vite.
    public var env: [String: String] = [:]
    /// La copia de la base que crea la preparación, si se pidió y se puede.
    public var database: WorktreeDatabase?

    public static func detects(_ path: String, read: (String) -> String? = readFile) -> Bool {
        read((path as NSString).appendingPathComponent("artisan")) != nil
            || read((path as NSString).appendingPathComponent("composer.json"))
                .flatMap(JSONValue.parse)?["require"]?["laravel/framework"] != nil
    }

    public static func readFile(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    public static func make(projectPath: String, worktreePath: String, herd: HerdSites?,
                            herdBinDirectory: String? = nil, ownDatabase: Bool = false,
                            read: (String) -> String? = readFile,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Self {
        func file(_ name: String) -> String? { read((projectPath as NSString).appendingPathComponent(name)) }
        var steps = ["set -e", "test -f .env || { printf '%s\\n' 'Falta .env: copiá la configuración local y reintentá.' >&2; exit 1; }",
                     "mkdir -p storage/app/public storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache"]
        var site: String?
        var url: String?
        var env: [String: String] = [:]
        if let herd {
            let folder = (worktreePath as NSString).lastPathComponent
            let prefix = (projectPath as NSString).lastPathComponent
            let raw = folder.hasPrefix(prefix + "-") ? folder : prefix + "-" + folder
            let slug = raw.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }.joined(separator: "-")
            let stem = String((slug.isEmpty ? "hive-worktree" : slug).prefix(50))
            var candidate = stem
            var suffix = 2
            func occupied(_ name: String) -> Bool {
                if let link = herd.links[name], !samePath(link, worktreePath) { return true }
                return herd.parkedPaths.contains {
                    let path = ($0 as NSString).appendingPathComponent(name)
                    return exists(path) && !samePath(path, worktreePath)
                }
            }
            while occupied(candidate) { candidate = "\(stem)-\(suffix)"; suffix += 1 }
            site = candidate
            let secure = herd.url(for: projectPath)?.hasPrefix("https://") == true
            url = "\(secure ? "https" : "http")://\(candidate).\(herd.tld)"
            steps += [
                herdBinDirectory.map { "export PATH=\(shellQuote($0)):\"$PATH\"" }
                    ?? "export PATH=\"$HOME/Library/Application Support/Herd/bin:$PATH\"",
                "hive_php=\"$(cd \(shellQuote(projectPath)) && herd which-php)\"",
                "hive_php_version=\"$(\"$hive_php\" -r 'echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;')\"",
            ]
            // Un sitio agregado después de la vista previa no se puede pisar al correr el script.
            let link = "\"$HOME/Library/Application Support/Herd/config/valet/Sites/\(candidate)\""
            let possibleSites = [link] + herd.parkedPaths.map { shellQuote(($0 as NSString).appendingPathComponent(candidate)) }
            for path in possibleSites {
                steps.append("if [ -e \(path) ] || [ -L \(path) ]; then test \"$(cd \(path) && pwd -P)\" = \"$(pwd -P)\" || { printf '%s\\n' 'El nombre del sitio de Herd ya está ocupado por otra carpeta.' >&2; exit 1; }; fi")
            }
            steps += ["herd link \(shellQuote(candidate))", "herd isolate \"$hive_php_version\" --site=\(shellQuote(candidate))"]
            if secure {
                steps.append("herd secure \(shellQuote(candidate))")
                // El plugin de Vite busca el certificado por el nombre de la carpeta («checkout.test»), pero
                // el sitio se llama «tienda-checkout». Sin esto, `npm run dev` sirve http y el navegador
                // bloquea el CSS y el JS de la página https.
                let certificates = herd.certificatesDirectory
                    ?? HerdSites.defaultRoot(home: FileManager.default.homeDirectoryForCurrentUser)
                        .appendingPathComponent("config/valet/Certificates").path
                let host = (certificates as NSString).appendingPathComponent("\(candidate).\(herd.tld)")
                env["VITE_DEV_SERVER_KEY"] = host + ".key"
                env["VITE_DEV_SERVER_CERT"] = host + ".crt"
            }
        }
        let database = ownDatabase ? file(".env").flatMap {
            WorktreeDatabase.plan(env: $0, projectPath: projectPath, worktreePath: worktreePath, exists: exists)
        } : nil
        if let database { env["DB_DATABASE"] = database.target }
        let php = herd == nil ? "php" : "herd php"
        let composer = herd == nil ? "composer" : "herd composer"
        // Composer puede ejecutar package:discover: .env y las carpetas ya tienen que existir.
        steps.append("\(composer) install --no-interaction")
        // Solo cachés locales: optimize:clear también vacía el cache compartido con el proyecto principal.
        steps.append("\(php) artisan config:clear --no-interaction")
        // No rotar una clave copiada ni ejecutar migraciones contra la conexión del proyecto principal.
        steps.append("hive_needs_key=\"$(\(php) -r \(shellQuote("require 'vendor/autoload.php'; $env = Dotenv\\Dotenv::parse(file_get_contents('.env')); echo empty($env['APP_KEY']) ? '1' : '0';")))\"")
        steps.append("if [ \"$hive_needs_key\" = 1 ]; then \(php) artisan key:generate --no-interaction; fi")
        steps.append("if [ ! -e public/storage ] && [ ! -L public/storage ]; then \(php) artisan storage:link --no-interaction; fi")
        if let database { steps += database.steps(php: php) }
        if let package = file("package.json").flatMap(JSONValue.parse) {
            let manager: String
            let install: String
            if file("pnpm-lock.yaml") != nil { manager = "pnpm"; install = "pnpm install --frozen-lockfile" }
            else if file("yarn.lock") != nil { manager = "yarn"; install = "yarn install" }
            else if file("bun.lock") != nil || file("bun.lockb") != nil { manager = "bun"; install = "bun install --frozen-lockfile" }
            else { manager = "npm"; install = file("package-lock.json") == nil ? "npm install" : "npm ci" }
            steps.append(install)
            if package["scripts"]?["build"] != nil { steps.append("\(manager) run build") }
        }
        steps.append("printf '%s\\n' \(shellQuote(url.map { "Worktree listo: \($0)" } ?? "Worktree Laravel listo."))")
        return Self(command: steps.joined(separator: "\n"), site: site, url: url, env: env, database: database)
    }
}

/// La base de datos propia de un worktree: una copia de la del proyecto principal, así las
/// migraciones y los datos de prueba de una rama no tocan a las otras. SQLite o MySQL/MariaDB en esta Mac.
public struct WorktreeDatabase: Equatable, Sendable {
    public enum Kind: String, Sendable { case sqlite, mysql }
    public var kind: Kind
    /// SQLite: el archivo del principal. MySQL: el nombre de su base.
    public var source: String
    /// SQLite: el archivo del worktree. MySQL: el nombre de la base nueva.
    public var target: String

    public init(kind: Kind, source: String, target: String) {
        self.kind = kind
        self.source = source
        self.target = target
    }

    /// Lo que se guarda en la rama para borrar la base con el worktree («mysql:tienda_checkout»).
    /// La de SQLite vive en la carpeta del worktree y se va con ella.
    public var stored: String? { kind == .mysql ? "mysql:\(target)" : nil }

    /// El nombre de una base MySQL guardada con `stored`.
    public static func mysqlName(stored: String?) -> String? {
        guard let stored, stored.hasPrefix("mysql:") else { return nil }
        let name = String(stored.dropFirst("mysql:".count))
        return isSafeName(name) ? name : nil
    }

    /// Para mostrar: «tienda_checkout» o «database/database.sqlite».
    public func label(worktreePath: String) -> String {
        guard kind == .sqlite else { return target }
        let prefix = worktreePath.hasSuffix("/") ? worktreePath : worktreePath + "/"
        return target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : (target as NSString).lastPathComponent
    }

    static let localHosts: Set<String> = ["", "127.0.0.1", "localhost", "::1"]

    /// Letras, números, «_» y «-»: el nombre va entre comillas invertidas en SQL y no se puede escapar.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Qué copiar según el .env del proyecto principal. Nil si usa otra base (PostgreSQL, una URL, un
    /// servidor que no está en esta Mac) o no hay nada que copiar.
    public static func plan(env: String, projectPath: String, worktreePath: String,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> WorktreeDatabase? {
        guard EnvFile.value("DB_URL", in: env)?.isEmpty != false else { return nil }
        switch EnvFile.value("DB_CONNECTION", in: env)?.lowercased() {
        case "sqlite":
            let database = EnvFile.value("DB_DATABASE", in: env) ?? "database/database.sqlite"
            guard !database.isEmpty, database != ":memory:", !database.contains("$") else { return nil }
            let source = database.hasPrefix("/") ? database : (projectPath as NSString).appendingPathComponent(database)
            guard exists(source) else { return nil }
            let relative = database.hasPrefix("/") ? "database/" + (database as NSString).lastPathComponent : database
            let target = (worktreePath as NSString).appendingPathComponent(relative)
            return samePath(source, target) ? nil : WorktreeDatabase(kind: .sqlite, source: source, target: target)
        case "mysql", "mariadb":
            guard localHosts.contains((EnvFile.value("DB_HOST", in: env) ?? "").lowercased()),
                  let source = EnvFile.value("DB_DATABASE", in: env), isSafeName(source) else { return nil }
            let folder = (worktreePath as NSString).lastPathComponent
            let prefix = (projectPath as NSString).lastPathComponent
            let branch = folder.lowercased().hasPrefix(prefix.lowercased() + "-") ? String(folder.dropFirst(prefix.count + 1)) : folder
            let slug = branch.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }.joined(separator: "_")
            guard !slug.isEmpty else { return nil }
            let target = String((source + "_" + slug).prefix(64))
            return target == source ? nil : WorktreeDatabase(kind: .mysql, source: source, target: target)
        default:
            return nil
        }
    }

    /// Pasos de la preparación que hacen la copia. Van después de `composer install`: la de MySQL lee
    /// el usuario y la contraseña del .env con Dotenv, así nunca quedan escritos en el comando.
    func steps(php: String) -> [String] {
        switch kind {
        case .sqlite:
            let backup = ".backup '" + target.replacingOccurrences(of: "'", with: "''") + "'"
            return [
                "mkdir -p \(shellQuote((target as NSString).deletingLastPathComponent))",
                // `.backup` copia bien aunque la app esté escribiendo (también en modo WAL). Si ya existe, se usa.
                "if [ ! -e \(shellQuote(target)) ]; then sqlite3 \(shellQuote(source)) \(shellQuote(backup)); "
                    + "printf '%s\\n' \(shellQuote("Base propia: copié \((source as NSString).lastPathComponent) para esta rama.")); fi",
            ]
        case .mysql:
            let read = "require 'vendor/autoload.php'; $e = Dotenv\\Dotenv::parse(file_get_contents('.env')); "
                + "foreach (['DB_HOST' => '127.0.0.1', 'DB_PORT' => '3306', 'DB_USERNAME' => 'root', 'DB_PASSWORD' => ''] as $k => $d) { "
                + "$v = (string) ($e[$k] ?? ''); echo 'hive_' . strtolower($k) . '=' . escapeshellarg($v === '' ? $d : $v) . PHP_EOL; }"
            let failure = "No pude copiar la base \(source) a \(target). Revisá que MySQL esté prendido y reintentá la preparación."
            return [
                "eval \"$(\(php) -r \(shellQuote(read)))\"",
                "hive_mysql() { MYSQL_PWD=\"$hive_db_password\" mysql --protocol=TCP -h \"$hive_db_host\" -P \"$hive_db_port\" -u \"$hive_db_username\" \"$@\"; }",
                "hive_mysqldump() { MYSQL_PWD=\"$hive_db_password\" mysqldump --protocol=TCP -h \"$hive_db_host\" -P \"$hive_db_port\" -u \"$hive_db_username\" \"$@\"; }",
                "command -v mysql >/dev/null && command -v mysqldump >/dev/null || { printf '%s\\n' "
                    + "\(shellQuote("No encontré mysql y mysqldump para copiar la base. Instalá el cliente de MySQL o creá el worktree sin «Base de datos propia».")) >&2; exit 1; }",
                "if [ -n \"$(hive_mysql -N -e \(shellQuote("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '\(target)'")))\" ]; then",
                "  printf '%s\\n' \(shellQuote("Base propia: \(target) ya existe, la uso tal cual."))",
                "else",
                "  hive_dump=\"$(mktemp -t havebee-db)\"",
                "  if hive_mysqldump --single-transaction --quick --routines --triggers --no-tablespaces \(shellQuote(source)) > \"$hive_dump\" "
                    + "&& hive_mysql -e \(shellQuote("CREATE DATABASE `\(target)`")) && hive_mysql \(shellQuote(target)) < \"$hive_dump\"; then",
                "    rm -f \"$hive_dump\"",
                "    printf '%s\\n' \(shellQuote("Base propia: copié \(source) a \(target)."))",
                "  else",
                "    rm -f \"$hive_dump\"",
                "    hive_mysql -e \(shellQuote("DROP DATABASE IF EXISTS `\(target)`")) || true",
                "    printf '%s\\n' \(shellQuote(failure)) >&2",
                "    exit 1",
                "  fi",
                "fi",
            ]
        }
    }
}
