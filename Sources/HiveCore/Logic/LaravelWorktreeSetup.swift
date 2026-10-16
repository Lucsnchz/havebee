import Foundation

/// La preparación se genera otra vez con la carpeta que git realmente creó, no con la vista previa.
public struct LaravelWorktreeSetup: Equatable, Sendable {
    public var command: String
    public var site: String?
    public var url: String?

    public static func detects(_ path: String, read: (String) -> String? = readFile) -> Bool {
        read((path as NSString).appendingPathComponent("artisan")) != nil
            || read((path as NSString).appendingPathComponent("composer.json"))
                .flatMap(JSONValue.parse)?["require"]?["laravel/framework"] != nil
    }

    public static func readFile(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    public static func make(projectPath: String, worktreePath: String, herd: HerdSites?,
                            herdBinDirectory: String? = nil,
                            read: (String) -> String? = readFile,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Self {
        func file(_ name: String) -> String? { read((projectPath as NSString).appendingPathComponent(name)) }
        var steps = ["set -e", "test -f .env || { printf '%s\\n' 'Falta .env: copiá la configuración local y reintentá.' >&2; exit 1; }",
                     "mkdir -p storage/app/public storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache"]
        var site: String?
        var url: String?
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
            if secure { steps.append("herd secure \(shellQuote(candidate))") }
        }
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
        return Self(command: steps.joined(separator: "\n"), site: site, url: url)
    }
}
