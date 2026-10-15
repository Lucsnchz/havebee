import Foundation

/// Comandos típicos según lo que tenga el repo: scripts de package.json, Laravel, composer, Docker.
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
        if exists("artisan") {
            found.append(Suggestion(name: "Servidor Laravel", command: "php artisan serve"))
            found.append(Suggestion(name: "Cola", command: "php artisan queue:work"))
        }
        if json("composer.json")?["scripts"]?["dev"] != nil {
            found.append(Suggestion(name: "Composer dev", command: "composer run dev"))
        }
        if ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"].contains(where: exists) {
            found.append(Suggestion(name: "Docker", command: "docker compose up"))
        }
        let taken = Set(existing.map(\.command))
        return found.filter { !taken.contains($0.command) }
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
