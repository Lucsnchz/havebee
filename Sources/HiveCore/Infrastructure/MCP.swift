import Foundation

/// Un servidor MCP tal como está en `.mcp.json` (guardamos todo el objeto para no perder campos).
public struct MCPServer: Identifiable, Equatable, Sendable {
    public var name: String
    public var config: [String: JSONValue]
    public var id: String { name }

    public init(name: String, config: [String: JSONValue]) {
        self.name = name
        self.config = config
    }

    public var command: String? { config["command"]?.string }
    public var args: [String] { config["args"]?.stringArray ?? [] }
    public var url: String? { config["url"]?.string ?? config["httpUrl"]?.string }
    public var env: [String: String] { config["env"]?.stringDictionary ?? [:] }
    public var isRemote: Bool { url != nil && command == nil }

    public var summary: String {
        if let url, command == nil { return url }
        return ([command ?? ""] + args).joined(separator: " ")
    }

    /// Ruta absoluta que no existe en esta Mac (ej. un .mcp.json armado en Windows con `C:/...`).
    public var brokenPath: String? {
        guard let command else { return nil }
        let looksAbsolute = command.hasPrefix("/") || command.range(of: #"^[A-Za-z]:[/\\]"#, options: .regularExpression) != nil
        return looksAbsolute && !FileManager.default.isExecutableFile(atPath: command) ? command : nil
    }
}

/// Por qué no se pudo usar un `.mcp.json`.
public enum MCPConfigError: Error, Equatable, Sendable, LocalizedError {
    /// El archivo existe, pero no se puede leer o no es un JSON válido. No lo tocamos para no perder servidores.
    case invalidJSON(String)

    public var path: String {
        switch self {
        case .invalidJSON(let path): path
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let path):
            "\((path as NSString).lastPathComponent) tiene un error de sintaxis o no se puede leer. "
                + "Corregilo a mano (\(path)) antes de cambiar los MCP desde Hive: así no se pierde ningún servidor."
        }
    }
}

/// Lee y escribe el `.mcp.json` del repo (el formato de Claude Code) y lo traduce para Codex y Gemini.
public enum MCPConfig {
    public static func url(in dir: String) -> URL {
        URL(fileURLWithPath: dir).appendingPathComponent(".mcp.json")
    }

    /// El `.mcp.json` de una carpeta o, en un worktree que no lo tiene, el del repo.
    public static func effectiveFile(directory: String, projectPath: String) -> URL? {
        let own = url(in: directory)
        if FileManager.default.fileExists(atPath: own.path) { return own }
        let main = url(in: projectPath)
        return FileManager.default.fileExists(atPath: main.path) ? main : nil
    }

    /// Los servidores del archivo, o el error si existe pero no se puede leer. Si no existe, no hay servidores.
    public static func loadResult(_ file: URL) -> Result<[MCPServer], MCPConfigError> {
        Result { try servers(in: readRoot(file)) }.mapError { $0 as? MCPConfigError ?? .invalidJSON(file.path) }
    }

    public static func loadResult(dir: String) -> Result<[MCPServer], MCPConfigError> { loadResult(url(in: dir)) }

    /// Igual que `loadResult`, pero sin distinguir el error: un archivo roto se lee como sin servidores.
    /// Lo usa el lanzamiento de sesiones, que no tiene cómo mostrar el problema.
    public static func load(_ file: URL) -> [MCPServer] {
        (try? loadResult(file).get()) ?? []
    }

    public static func load(dir: String) -> [MCPServer] { load(url(in: dir)) }

    /// Agrega o reemplaza un servidor, conservando el resto del archivo.
    /// Si el archivo no se puede leer, lanza `MCPConfigError` sin tocarlo.
    public static func upsert(_ server: MCPServer, replacing oldName: String? = nil, dir: String) throws {
        var root = try readRoot(url(in: dir))
        var servers = root["mcpServers"]?.object ?? [:]
        if let oldName, oldName != server.name { servers.removeValue(forKey: oldName) }
        servers[server.name] = .object(server.config)
        root["mcpServers"] = .object(servers)
        try write(root, dir: dir)
    }

    /// Quita un servidor. Si no estaba, no escribe nada; si el archivo no se puede leer, lanza sin tocarlo.
    public static func remove(_ name: String, dir: String) throws {
        var root = try readRoot(url(in: dir))
        var servers = root["mcpServers"]?.object ?? [:]
        guard servers.removeValue(forKey: name) != nil else { return }
        root["mcpServers"] = .object(servers)
        try write(root, dir: dir)
    }

    /// El objeto raíz del archivo. Un archivo que no existe es un objeto vacío; uno que no se puede
    /// leer o parsear es un error, porque reescribirlo borraría lo que tiene.
    static func readRoot(_ file: URL) throws -> [String: JSONValue] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return [:]
        } catch {
            throw MCPConfigError.invalidJSON(file.path)
        }
        return try parseRoot(data, path: file.path)
    }

    static func parseRoot(_ data: Data, path: String) throws -> [String: JSONValue] {
        if let root = JSONValue.parse(data)?.object {
            // `mcpServers` tiene que ser un objeto (o null, que no tiene nada): si es otra cosa, reemplazarlo perdería datos.
            if let servers = root["mcpServers"], servers != .null, servers.object == nil { throw MCPConfigError.invalidJSON(path) }
            return root
        }
        // Sin comillas ni `:` no puede haber servidores ni otros datos (vacío, `{roto`, `null`, `[]`): se trata
        // como un archivo vacío. Con algo que parezca `clave: valor` (aunque sea sin comillas o con comillas
        // simples, como `{ mcpServers: { … } }`), mejor no tocarlo.
        let markers: Set<UInt8> = [UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: ":")]
        if !data.contains(where: markers.contains) { return [:] }
        throw MCPConfigError.invalidJSON(path)
    }

    private static func servers(in root: [String: JSONValue]) -> [MCPServer] {
        (root["mcpServers"]?.object ?? [:])
            .compactMap { name, value in value.object.map { MCPServer(name: name, config: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func write(_ root: [String: JSONValue], dir: String) throws {
        let data = try JSONSerialization.data(withJSONObject: JSONValue.object(root).anyValue,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // JSONSerialization escribe `"clave" : valor`; lo dejamos como el formato habitual `"clave": valor`.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"(?m)^(\s*"(?:[^"\\]|\\.)*") : "#, with: "$1: ", options: .regularExpression)
        try Data((text + "\n").utf8).write(to: url(in: dir), options: .atomic)
    }

    // MARK: - Para Codex

    /// `-c mcp_servers.<nombre>.…` para que Codex vea los MCP del proyecto.
    public static func codexOverrides(_ servers: [MCPServer]) -> [String] {
        var args: [String] = []
        for server in servers {
            let key = "mcp_servers.\(TOML.bareKey(server.name))"
            if let command = server.command {
                args += ["-c", "\(key).command=\(TOML.string(command))"]
                if !server.args.isEmpty { args += ["-c", "\(key).args=[\(server.args.map(TOML.string).joined(separator: ","))]"] }
                if !server.env.isEmpty {
                    let pairs = server.env.sorted { $0.key < $1.key }.map { "\(TOML.string($0.key))=\(TOML.string($0.value))" }
                    args += ["-c", "\(key).env={\(pairs.joined(separator: ","))}"]
                }
            } else if let url = server.url {
                args += ["-c", "\(key).url=\(TOML.string(url))"]
            }
        }
        return args
    }

    // MARK: - Para Gemini

    /// Ajustes "de sistema" de Gemini con los MCP del proyecto (GEMINI_CLI_SYSTEM_SETTINGS_PATH).
    public static func geminiSettings(_ servers: [MCPServer]) -> JSONValue? {
        guard !servers.isEmpty else { return nil }
        var mcp: [String: JSONValue] = [:]
        for server in servers {
            var entry: [String: JSONValue] = [:]
            if let command = server.command {
                entry["command"] = .string(command)
                if !server.args.isEmpty { entry["args"] = .array(server.args.map(JSONValue.string)) }
                if !server.env.isEmpty { entry["env"] = .object(server.env.mapValues(JSONValue.string)) }
            } else if let url = server.url {
                entry["httpUrl"] = .string(url)
            }
            mcp[server.name] = .object(entry)
        }
        return .object(["mcpServers": .object(mcp)])
    }

    /// Escribe esos ajustes y devuelve la ruta (o nil si no hay MCP).
    public static func writeGeminiSettings(_ servers: [MCPServer], to file: URL) -> String? {
        guard let settings = geminiSettings(servers),
              let data = try? JSONSerialization.data(withJSONObject: settings.anyValue, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: file)) == nil ? nil : file.path
    }

    // MARK: - Globales (solo lectura)

    public struct GlobalGroup: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let servers: [Entry]

        public struct Entry: Equatable, Sendable {
            public let name: String
            public let summary: String
        }
    }

    /// Los MCP que cada agente ya tiene configurados por fuera del proyecto.
    public static func globals(projectPath: String, home: URL, codexHome: URL) -> [GlobalGroup] {
        var groups: [GlobalGroup] = []
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")), let root = JSONValue.parse(data) {
            let user = entries(root["mcpServers"]?.object)
            if !user.isEmpty { groups.append(GlobalGroup(id: "claude-user", title: "Claude · todos tus proyectos", servers: user)) }
            let local = entries(root["projects"]?[projectPath]?["mcpServers"]?.object)
            if !local.isEmpty { groups.append(GlobalGroup(id: "claude-local", title: "Claude · solo vos en este proyecto", servers: local)) }
        }
        if let text = try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8) {
            let codex = codexEntries(text)
            if !codex.isEmpty { groups.append(GlobalGroup(id: "codex", title: "Codex · config.toml", servers: codex)) }
        }
        if let data = try? Data(contentsOf: home.appendingPathComponent(".gemini/settings.json")), let root = JSONValue.parse(data) {
            let gemini = entries(root["mcpServers"]?.object)
            if !gemini.isEmpty { groups.append(GlobalGroup(id: "gemini", title: "Gemini · settings.json", servers: gemini)) }
        }
        return groups
    }

    private static func entries(_ servers: [String: JSONValue]?) -> [GlobalGroup.Entry] {
        (servers ?? [:]).compactMap { name, value in
            value.object.map { GlobalGroup.Entry(name: name, summary: MCPServer(name: name, config: $0).summary) }
        }
        .sorted { $0.name < $1.name }
    }

    /// Las tablas `[mcp_servers.<nombre>]` de un config.toml de Codex, con su comando o URL.
    static func codexEntries(_ text: String) -> [GlobalGroup.Entry] {
        var result: [GlobalGroup.Entry] = []
        var current: String?
        var summary = ""
        func flush() { if let current { result.append(GlobalGroup.Entry(name: current, summary: summary)) } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[mcp_servers.") && line.hasSuffix("]") {
                let name = String(line.dropFirst("[mcp_servers.".count).dropLast())
                if name.contains(".") { continue } // subtablas como [mcp_servers.x.env]
                flush()
                current = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                summary = ""
            } else if line.hasPrefix("[") {
                flush()
                current = nil
            } else if current != nil, summary.isEmpty, line.hasPrefix("command") || line.hasPrefix("url") {
                summary = line.components(separatedBy: "=").dropFirst().joined(separator: "=")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
        }
        flush()
        return result
    }

    /// Separa una línea de comando en palabras, como un shell: respeta comillas simples y dobles, y la
    /// barra invertida escapa un espacio, una comilla u otra barra (`a\ b`, `"di \"hola\""`). Fuera de eso
    /// la barra queda tal cual, así una ruta de Windows como `C:\tools\x.exe` no se rompe.
    public static func splitCommandLine(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if let q = quote {
                if char == q {
                    quote = nil
                } else if q == "\"", char == "\\", let next, next == "\"" || next == "\\" {
                    current.append(next)
                    index += 1
                } else {
                    current.append(char)
                }
            } else if char == "\\", let next, next == " " || next == "\t" || next == "\"" || next == "'" || next == "\\" {
                current.append(next)
                hasWord = true
                index += 1
            } else if char == "\"" || char == "'" {
                quote = char
                hasWord = true
            } else if char == " " || char == "\t" {
                if hasWord || !current.isEmpty { words.append(current); current = ""; hasWord = false }
            } else {
                current.append(char)
            }
            index += 1
        }
        if hasWord || !current.isEmpty { words.append(current) }
        return words
    }

    /// Lo inverso de `splitCommandLine`: arma una línea que, al separarla, devuelve exactamente las mismas palabras.
    public static func joinCommandLine(_ words: [String]) -> String {
        words.map(quoteWord).joined(separator: " ")
    }

    /// Una palabra lista para la línea de comando: tal cual si es simple, entre comillas simples si tiene
    /// espacios, comillas dobles o barras, y entre comillas dobles (escapando) si tiene un apóstrofo.
    static func quoteWord(_ word: String) -> String {
        if word.isEmpty { return "\"\"" }
        let needsQuotes = word.contains { $0 == "\"" || $0 == "'" || $0 == "\\" || $0.isWhitespace }
        guard needsQuotes else { return word }
        if !word.contains("'") { return "'\(word)'" }
        let escaped = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// MCP conocidos según el stack del proyecto.
public enum MCPCatalog {
    public struct Item: Identifiable, Equatable, Sendable {
        public let name: String
        public let detail: String
        public let config: [String: JSONValue]
        public var id: String { name }
    }

    public static func suggestions(projectPath: String, home: URL, existing: [MCPServer]) -> [Item] {
        let fm = FileManager.default
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: (projectPath as NSString).appendingPathComponent(path)) }
        var items: [Item] = []

        if exists("artisan") {
            items.append(Item(name: "laravel-boost", detail: "Laravel Boost: docs, base de datos, rutas y logs de tu app (requiere laravel/boost).",
                              config: ["command": "php", "args": ["artisan", "boost:mcp"]]))
            let herd = home.appendingPathComponent("Library/Application Support/Herd/bin/herd-mcp.phar").path
            if fm.fileExists(atPath: herd) {
                items.append(Item(name: "herd", detail: "Laravel Herd: sitios, PHP, servicios y logs locales.",
                                  config: ["command": "php", "args": [.string(herd)], "env": ["SITE_PATH": .string(projectPath)]]))
            }
            items.append(Item(name: "nightwatch", detail: "Laravel Nightwatch: errores y rendimiento en producción.",
                              config: ["command": "npx", "args": ["-y", "mcp-remote", "https://nightwatch.laravel.com/mcp"]]))
        }
        let package = (fm.contents(atPath: (projectPath as NSString).appendingPathComponent("package.json"))).flatMap(JSONValue.parse)
        let deps = (package?["dependencies"]?.object ?? [:]).merging(package?["devDependencies"]?.object ?? [:]) { a, _ in a }
        if deps["next"] != nil {
            items.append(Item(name: "next-devtools", detail: "Next.js: errores, rutas y docs de tu app en desarrollo.",
                              config: ["command": "npx", "args": ["-y", "next-devtools-mcp@latest"]]))
        }
        if package != nil {
            items.append(Item(name: "playwright", detail: "Playwright: la IA abre el navegador y prueba la app.",
                              config: ["command": "npx", "args": ["@playwright/mcp@latest"]]))
            items.append(Item(name: "chrome-devtools", detail: "Chrome DevTools: consola, red y rendimiento de la página.",
                              config: ["command": "npx", "args": ["-y", "chrome-devtools-mcp@latest"]]))
        }
        if exists("gradlew") || exists("build.gradle") || exists("build.gradle.kts") || exists("pubspec.yaml") {
            items.append(Item(name: "mobile-mcp", detail: "Emuladores y dispositivos Android/iOS: capturas, toques y logs.",
                              config: ["command": "npx", "args": ["-y", "@mobilenext/mobile-mcp@latest"]]))
        }
        let rootItems = (try? fm.contentsOfDirectory(atPath: projectPath)) ?? []
        if exists("Package.swift") || rootItems.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            items.append(Item(name: "XcodeBuildMCP", detail: "Xcode: compilar, correr en el simulador y leer errores.",
                              config: ["command": "npx", "args": ["-y", "xcodebuildmcp@latest"]]))
        }
        items.append(Item(name: "context7", detail: "Context7: documentación actualizada de cualquier librería.",
                          config: ["command": "npx", "args": ["-y", "@upstash/context7-mcp"]]))

        let names = Set(existing.map(\.name))
        let summaries = Set(existing.map(\.summary))
        return items.filter { item in
            !names.contains(item.name) && !summaries.contains(MCPServer(name: item.name, config: item.config).summary)
        }
    }
}
