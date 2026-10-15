import Foundation

/// Comandos típicos según lo que tenga el repo: scripts de package.json, Laravel, composer, Docker y Android (Gradle).
public enum CommandSuggestions {
    public struct Suggestion: Equatable, Sendable {
        public let name: String
        public let command: String
    }

    public static func detect(projectPath root: String, existing: [ProjectCommand] = []) -> [Suggestion] {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: (root as NSString).appendingPathComponent(name)) }
        func json(_ name: String) -> JSONValue? { fm.contents(atPath: (root as NSString).appendingPathComponent(name)).flatMap(JSONValue.parse) }
        var found: [Suggestion] = []

        if let scripts = json("package.json")?["scripts"]?.object {
            let runner: String
            if exists("pnpm-lock.yaml") { runner = "pnpm" }
            else if exists("yarn.lock") { runner = "yarn" }
            else if exists("bun.lockb") || exists("bun.lock") { runner = "bun run" }
            else { runner = "npm run" }
            for name in ["dev", "start", "serve", "watch", "build", "test", "lint", "preview"] where scripts[name] != nil {
                found.append(Suggestion(name: name.capitalized, command: "\(runner) \(name)"))
            }
        }
        let composer = json("composer.json")
        if exists("artisan") {
            found.append(Suggestion(name: "Servidor Laravel", command: "php artisan serve"))
            found.append(Suggestion(name: "Cola", command: "php artisan queue:work"))
            found.append(Suggestion(name: "Tests", command: "php artisan test"))
            if composer?["require"]?["laravel/pail"] != nil || composer?["require-dev"]?["laravel/pail"] != nil {
                found.append(Suggestion(name: "Logs", command: "php artisan pail"))
            }
        }
        if composer?["scripts"]?["dev"] != nil {
            found.append(Suggestion(name: "Composer dev", command: "composer run dev"))
        }
        if exists("gradlew") {
            found.append(Suggestion(name: "Compilar debug", command: "./gradlew assembleDebug"))
            found.append(Suggestion(name: "Instalar en el teléfono", command: "./gradlew installDebug"))
            found.append(Suggestion(name: "Tests", command: "./gradlew testDebugUnitTest"))
            found.append(Suggestion(name: "Lint", command: "./gradlew lint"))
            if let id = androidApplicationId(projectPath: root) {
                found.append(Suggestion(name: "Logcat de la app", command: "adb logcat --pid=$(adb shell pidof -s \(id))"))
            }
        }
        if ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"].contains(where: exists) {
            found.append(Suggestion(name: "Docker", command: "docker compose up"))
        }
        let taken = Set(existing.map(\.command))
        return found.filter { !taken.contains($0.command) }
    }

    /// El applicationId de la app Android, leído de `app/build.gradle.kts` o `app/build.gradle`.
    /// Si no está, Gradle usa el `namespace`, así que ese es el respaldo.
    public static func androidApplicationId(projectPath root: String) -> String? {
        for file in ["app/build.gradle.kts", "app/build.gradle"] {
            let path = (root as NSString).appendingPathComponent(file)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let id = gradleString("applicationId", in: text) ?? gradleString("namespace", in: text) { return id }
        }
        return nil
    }

    /// El valor de `clave = "x"`, `clave "x"` o `clave("x")` al principio de una línea (no en un comentario).
    /// Solo acepta un nombre de paquete válido, así se puede usar sin comillas en un comando.
    static func gradleString(_ key: String, in text: String) -> String? {
        let pattern = #"(?m)^\s*"# + key + #"\s*(?:=\s*|\(\s*)?["']([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Busca un logo dentro del repo para usarlo como ícono del proyecto.
/// `isUsable` decide si un archivo es una imagen que sirve (la app lo hace con AppKit).
public struct LogoFinder: Sendable {
    /// En orden de preferencia: íconos cuadrados y grandes primero, favicons chicos al final.
    public static let candidates = [
        "public/apple-touch-icon.png", "public/brand/apple-touch-icon.png", "static/apple-touch-icon.png",
        "apple-touch-icon.png", "public/images/apple-touch-icon.png",
        "public/logo_icon.png", "public/logo-icon.png", "public/icon.png", "app/icon.png", "src/app/icon.png",
        "assets/icon.png", "assets/icon/icon.png", "assets/images/icon.png", "icon.png", "build/icon.png",
        "app/src/main/ic_launcher-playstore.png",
        "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png", "app/src/main/res/mipmap-xxxhdpi/ic_launcher.webp",
        "app/src/main/res/mipmap-xxhdpi/ic_launcher.png", "app/src/main/res/mipmap-xxhdpi/ic_launcher.webp",
        "public/favicon.svg", "public/favicon.png", "static/favicon.png", "src/favicon.png", "public/favicon-32x32.png",
        "public/logo.png", "public/images/logo.png", "public/img/logo.png", "src/assets/logo.png", "assets/logo.png",
        "logo.png", "public/logo.svg", "src/assets/logo.svg", "logo.svg", ".github/logo.png", "docs/logo.png",
        "public/favicon.ico", "public/brand/favicon.ico", "static/favicon.ico", "app/favicon.ico", "src/app/favicon.ico",
        "favicon.ico",
    ]

    private let isUsable: @Sendable (String) -> Bool

    public init(isUsable: @escaping @Sendable (String) -> Bool) {
        self.isUsable = isUsable
    }

    /// Todos los logos válidos del repo, el mejor primero.
    public func find(in root: String) -> [String] {
        var found: [String] = []
        for relative in Self.candidates {
            let path = (root as NSString).appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: path), isUsable(path) { found.append(path) }
        }
        found.append(contentsOf: xcodeAppIcons(in: root))
        return found
    }

    /// El PNG más grande de un AppIcon.appiconset (proyectos de Xcode), hasta un nivel adentro.
    private func xcodeAppIcons(in root: String) -> [String] {
        let fm = FileManager.default
        var dirs = [root]
        for child in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !child.hasPrefix(".") {
            dirs.append((root as NSString).appendingPathComponent(child))
        }
        for dir in dirs {
            let set = (dir as NSString).appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
            guard let files = try? fm.contentsOfDirectory(atPath: set) else { continue }
            let pngs = files.filter { $0.lowercased().hasSuffix(".png") }.map { (set as NSString).appendingPathComponent($0) }
            func size(_ path: String) -> Int { (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0 }
            if let largest = pngs.max(by: { size($0) < size($1) }), isUsable(largest) { return [largest] }
        }
        return []
    }
}
