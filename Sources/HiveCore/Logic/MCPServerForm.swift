import Foundation

/// Lo que se edita en la hoja de un MCP, separado de la vista para poder probarlo.
///
/// Guarda exactamente lo que se cargó: si no tocás el comando, la URL o el entorno, esos campos
/// quedan como estaban en el `.mcp.json` (con su `type`, sus `headers` y cualquier otro campo
/// que Hive no conoce). Solo al pasar de local a remoto, o al revés, limpia lo del otro tipo.
public struct MCPServerForm: Equatable, Sendable {
    public var name: String
    public var remote: Bool
    /// Comando y argumentos en una línea, con comillas donde hace falta.
    public var commandLine: String
    public var url: String
    /// Variables de entorno, una por línea: `CLAVE=valor`.
    public var environment: String

    /// Campos que solo tienen sentido en un servidor local (se ejecuta un comando).
    static let localKeys = ["command", "args", "env", "cwd"]
    /// Campos que solo tienen sentido en un servidor remoto (se conecta a una URL).
    static let remoteKeys = ["url", "httpUrl", "headers"]

    public init(name: String = "", remote: Bool = false, commandLine: String = "", url: String = "", environment: String = "") {
        self.name = name
        self.remote = remote
        self.commandLine = commandLine
        self.url = url
        self.environment = environment
    }

    public init(server: MCPServer) {
        self.init(name: server.name,
                  remote: server.isRemote,
                  commandLine: MCPConfig.joinCommandLine(Self.words(of: server)),
                  url: server.url ?? "",
                  environment: Self.environmentText(server.env))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Tiene nombre y, según el tipo, un comando o una URL http(s).
    public var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        if remote { return isValidURL }
        return !(MCPConfig.splitCommandLine(commandLine).first ?? "").isEmpty
    }

    /// Una URL http o https con servidor (`https://ejemplo.com/mcp`).
    public var isValidURL: Bool {
        guard let parsed = URL(string: trimmedURL), let scheme = parsed.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && !(parsed.host ?? "").isEmpty
    }

    /// Si el nombre ya lo usa otro servidor del archivo (sin contar el que se está editando).
    public func nameIsTaken(by existing: [String], editing: String?) -> Bool {
        trimmedName != editing && existing.contains(trimmedName)
    }

    /// El servidor que queda al guardar. `original` es el que se abrió (nil si es nuevo).
    public func apply(to original: MCPServer?) -> MCPServer {
        var config = original?.config ?? [:]
        let switched = original.map { $0.isRemote != remote } ?? false

        if remote {
            if switched { for key in Self.localKeys { config.removeValue(forKey: key) } }
            if original == nil || switched || config["type"]?.string == "stdio" { config["type"] = "http" }
            if trimmedURL != original?.url {
                // Respetamos la clave que ya usaba el archivo (`httpUrl` es el formato de Gemini).
                let key = config["url"] == nil && config["httpUrl"] != nil ? "httpUrl" : "url"
                config[key] = .string(trimmedURL)
            }
        } else {
            if switched {
                for key in Self.remoteKeys { config.removeValue(forKey: key) }
                if config["type"]?.string != "stdio" { config.removeValue(forKey: "type") }
            }
            let words = MCPConfig.splitCommandLine(commandLine)
            if switched || original.map(Self.words(of:)) != words {
                config["command"] = .string(words.first ?? "")
                if words.count > 1 { config["args"] = .array(words.dropFirst().map(JSONValue.string)) } else { config.removeValue(forKey: "args") }
            }
            if switched || environment != Self.environmentText(original?.env ?? [:]) {
                let env = Self.parseEnvironment(environment)
                if env.isEmpty { config.removeValue(forKey: "env") } else { config["env"] = .object(env.mapValues(JSONValue.string)) }
            }
        }
        return MCPServer(name: trimmedName, config: config)
    }

    /// Comando y argumentos de un servidor (vacío si no tiene comando).
    static func words(of server: MCPServer) -> [String] {
        server.command.map { [$0] + server.args } ?? []
    }

    // MARK: - Entorno

    /// `CLAVE=valor`, una por línea, ordenadas por clave.
    public static func environmentText(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    /// Lee `CLAVE=valor` por línea. El valor puede tener `=`; se saltean las líneas vacías, los
    /// comentarios (`#`) y las que no tienen clave. Acepta `export CLAVE=valor`, como en un `.env`.
    public static func parseEnvironment(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return env
    }
}
