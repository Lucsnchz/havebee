import Foundation

/// Scripts para preparar un worktree nuevo (setup) y para limpiarlo antes de borrarlo (archive).
/// Se toman de polyscope.json o conductor.json (compatibles con esas apps) y, si no hay, se sugiere
/// uno según el stack. Hive no los corre acá: los devuelve como texto.
public enum ProjectScripts {
    public enum Origin: String, Sendable {
        case polyscope, conductor, suggested

        /// «Tomado de polyscope.json», para mostrar de dónde salió.
        public var label: String {
            switch self {
            case .polyscope: "Tomado de polyscope.json"
            case .conductor: "Tomado de conductor.json"
            case .suggested: "Sugerido para este proyecto"
            }
        }
    }

    public struct Script: Equatable, Sendable {
        public var command: String
        public var origin: Origin

        public init(command: String, origin: Origin) {
            self.command = command
            self.origin = origin
        }
    }

    public struct Resolved: Equatable, Sendable {
        public var setup: Script?
        public var archive: Script?

        public init(setup: Script? = nil, archive: Script? = nil) {
            self.setup = setup
            self.archive = archive
        }
    }

    /// - Parameters:
    ///   - folder: nombre de la carpeta del worktree (para `herd secure <carpeta>`).
    ///   - mainHasCert: el sitio de la carpeta principal tiene HTTPS en Herd.
    public static func resolve(projectPath: String, folder: String, mainHasCert: Bool,
                               read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Resolved {
        func json(_ name: String) -> JSONValue? {
            read((projectPath as NSString).appendingPathComponent(name)).flatMap(JSONValue.parse)
        }
        var resolved = Resolved()
        for (file, origin) in [("polyscope.json", Origin.polyscope), ("conductor.json", .conductor)] {
            guard let scripts = json(file)?["scripts"] else { continue }
            if resolved.setup == nil, let setup = command(scripts["setup"]) { resolved.setup = Script(command: setup, origin: origin) }
            if resolved.archive == nil, let archive = command(scripts["archive"]) { resolved.archive = Script(command: archive, origin: origin) }
        }
        if resolved.setup == nil, let suggested = suggestedSetup(projectPath: projectPath, read: read) {
            resolved.setup = Script(command: suggested, origin: .suggested)
        }
        if mainHasCert {
            let secure = "herd secure \(quoteIfNeeded(folder))"
            if let setup = resolved.setup {
                if !setup.command.contains("herd secure") { resolved.setup?.command = setup.command + " && " + secure }
            } else {
                resolved.setup = Script(command: secure, origin: .suggested)
            }
        }
        return resolved
    }

    /// Un script puede ser un texto o una lista de comandos (se unen con &&).
    static func command(_ value: JSONValue?) -> String? {
        let text: String?
        if let string = value?.string {
            text = string
        } else if let list = value?.stringArray {
            text = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " && ")
        } else {
            text = nil
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Instalación típica según el stack. En Android no hace falta nada (alcanza con copiar local.properties).
    static func suggestedSetup(projectPath: String, read: (String) -> String?) -> String? {
        func file(_ name: String) -> String? { read((projectPath as NSString).appendingPathComponent(name)) }
        func has(_ name: String) -> Bool { file(name) != nil }
        let package = file("package.json").flatMap(JSONValue.parse)
        let composer = has("composer.json")
        var steps: [String] = []
        if composer { steps.append("composer install") }
        if let package {
            let manager: String
            if has("pnpm-lock.yaml") { manager = "pnpm" }
            else if has("yarn.lock") { manager = "yarn" }
            else if has("bun.lockb") || has("bun.lock") { manager = "bun" }
            else { manager = "npm" }
            steps.append("\(manager) install")
            // Laravel compila los assets con Vite: sin build, «Vite manifest not found».
            if composer, package["scripts"]?["build"] != nil { steps.append("\(manager) run build") }
        }
        return steps.isEmpty ? nil : steps.joined(separator: " && ")
    }

    /// Variables para los scripts. Los alias de Conductor hacen que sus scripts funcionen tal cual.
    public static func environment(rootPath: String, worktreePath: String, branch: String) -> [String: String] {
        let folder = (worktreePath as NSString).lastPathComponent
        return [
            "HIVE_ROOT_PATH": rootPath,
            "HIVE_WORKTREE_PATH": worktreePath,
            "HIVE_BRANCH": branch,
            "HIVE_FOLDER": folder,
            "CONDUCTOR_ROOT_PATH": rootPath,
            "CONDUCTOR_WORKSPACE_NAME": folder,
        ]
    }

    private static func quoteIfNeeded(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        return text.unicodeScalars.allSatisfy(safe.contains) && !text.isEmpty ? text : shellQuote(text)
    }
}
