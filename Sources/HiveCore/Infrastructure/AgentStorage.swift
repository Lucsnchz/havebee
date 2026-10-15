import CryptoKit
import Foundation

/// Dónde guardan sus conversaciones Claude, Codex y Gemini, para poder reanudarlas.
/// Las carpetas se inyectan para que los tests usen carpetas temporales.
public struct AgentStorage: Sendable {
    public let claudeConfigDir: URL
    public let codexHome: URL
    public let geminiHome: URL

    public init(claudeConfigDir: URL, codexHome: URL, geminiHome: URL) {
        self.claudeConfigDir = claudeConfigDir
        self.codexHome = codexHome
        self.geminiHome = geminiHome
    }

    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentStorage {
        func dir(_ key: String, default path: String) -> URL {
            if let value = environment[key], !value.isEmpty { return URL(fileURLWithPath: value) }
            return home.appendingPathComponent(path)
        }
        return AgentStorage(claudeConfigDir: dir("CLAUDE_CONFIG_DIR", default: ".claude"),
                            codexHome: dir("CODEX_HOME", default: ".codex"),
                            geminiHome: home.appendingPathComponent(".gemini"))
    }

    /// Claude guarda cada conversación en <config>/projects/<carpeta>/<id>.jsonl.
    /// Si no existe, la sesión nunca recibió un mensaje y hay que arrancarla de cero.
    public func claudeConversationExists(_ id: String) -> Bool {
        claudeTranscriptURL(id) != nil
    }

    /// El transcript de una conversación de Claude (<config>/projects/<carpeta>/<id>.jsonl), si existe.
    public func claudeTranscriptURL(_ id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        let base = claudeConfigDir.appendingPathComponent("projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return nil }
        for dir in dirs.sorted() {
            let file = base.appendingPathComponent(dir).appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// El statusLine que ya tenías en Claude, para que el de Hive lo siga mostrando. Gana el más específico:
    /// .claude/settings.local.json y .claude/settings.json de la carpeta, y después <config>/settings.json.
    public func claudeUserStatusLine(directory: String) -> String? {
        let project = URL(fileURLWithPath: directory).appendingPathComponent(".claude")
        let files = [project.appendingPathComponent("settings.local.json"), project.appendingPathComponent("settings.json"),
                     claudeConfigDir.appendingPathComponent("settings.json")]
        for file in files {
            guard let data = try? Data(contentsOf: file), let settings = JSONValue.parse(data),
                  let statusLine = settings["statusLine"] else { continue }
            let type = statusLine["type"]?.string ?? "command"
            guard type == "command", let command = statusLine["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else { continue }
            // El de Hive nunca se encadena a sí mismo.
            if command.contains("claude-status") && command.contains("HIVE_EVENT_BIN") { continue }
            return command
        }
        return nil
    }

    /// El `notify` que ya tenías en el config.toml de Codex (para seguir llamándolo).
    public func codexExistingNotify() -> [String]? {
        guard let text = try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8) else { return nil }
        return CodexNotify.existing(inConfig: text)
    }

    /// Plan B para reanudar Codex: si nunca llegó un thread-id (por ejemplo, cortaste el primer turno),
    /// buscamos el archivo de sesión que Codex creó en esa carpeta después del último arranque.
    /// Se descartan los subagentes y las ventanas de VS Code, y gana el creado más cerca del arranque
    /// (no el último modificado: un subagente o un thread ajeno puede escribir después).
    public func discoverCodexThread(cwd: String, since: Date, excluding: Set<String>, now: Date = Date()) -> String? {
        let fm = FileManager.default
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: since.addingTimeInterval(-86_400))
        let threshold = since.addingTimeInterval(-5)
        var best: (distance: TimeInterval, id: String)?
        while day <= now {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = codexHome.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                // Lo que no se escribió desde el arranque tampoco se creó después: ni lo abrimos.
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= threshold,
                      let meta = Self.firstLineJSON(file),
                      let payload = meta["payload"],
                      let id = payload["id"]?.string,
                      let sessionDir = payload["cwd"]?.string,
                      samePath(sessionDir, cwd),
                      !excluding.contains(id),
                      !Self.isSubagentMeta(payload),
                      payload["source"]?.string != "vscode" else { continue }
                let created = (payload["timestamp"]?.string ?? meta["timestamp"]?.string).flatMap(AgentTimestamp.parse) ?? modified
                guard created >= threshold else { continue }
                let distance = abs(created.timeIntervalSince(since))
                if best == nil || distance < best!.distance { best = (distance, id) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return best?.id
    }

    /// Si un thread de Codex es de un subagente (su session_meta dice `source.subagent`).
    /// Sus avisos llegan por el mismo notify que el padre y no tienen que cambiar la sesión.
    public func isCodexSubagentThread(_ id: String) -> Bool {
        guard let url = codexRolloutURL(id), let meta = Self.firstLineJSON(url) else { return false }
        return Self.isSubagentMeta(meta["payload"])
    }

    /// El archivo de un thread de Codex: sessions/AAAA/MM/DD/rollout-<fecha>-<thread>.jsonl
    /// (o archived_sessions/ si lo archivaste).
    public func codexRolloutURL(_ threadId: String) -> URL? {
        guard !threadId.isEmpty else { return nil }
        let key = codexHome.path + "|" + threadId
        if let cached = Self.rolloutCache.get(key), FileManager.default.fileExists(atPath: cached.path) { return cached }
        let suffix = "-\(threadId).jsonl"
        for folder in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.lastPathComponent.hasSuffix(suffix) {
                Self.rolloutCache.set(key, file)
                return file
            }
        }
        return nil
    }

    static func isSubagentMeta(_ payload: JSONValue?) -> Bool {
        guard let payload else { return false }
        if payload["thread_source"]?.string == "subagent" { return true }
        switch payload["source"] {
        case .object(let source)?: return source["subagent"] != nil
        case .string(let source)?: return source == "subagent"
        default: return false
        }
    }

    private static let rolloutCache = AgentStorageURLCache()

    /// Gemini no deja fijar el ID de sesión al arrancar: buscamos el chat que guardó en esa carpeta
    /// (<home>/tmp/<hash>/chats/*.json) después del último arranque. Si no hay, arranca de cero.
    public func discoverGeminiSession(cwd: String, since: Date, excluding: Set<String>) -> String? {
        let fm = FileManager.default
        let base = geminiHome.appendingPathComponent("tmp")
        let hash = Self.sha256(URL(fileURLWithPath: cwd).standardizedFileURL.path)
        let threshold = since.addingTimeInterval(-5)
        var best: (date: Date, id: String)?
        for project in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            let chats = base.appendingPathComponent(project).appendingPathComponent("chats")
            let files = (try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "json" {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= threshold,
                      let data = try? Data(contentsOf: file),
                      let json = JSONValue.parse(data),
                      let id = json["sessionId"]?.string, !excluding.contains(id) else { continue }
                if let projectHash = json["projectHash"]?.string, projectHash != hash { continue }
                if json["projectHash"] == nil && project != hash { continue }
                if best == nil || modified > best!.date { best = (modified, id) }
            }
        }
        return best?.id
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func firstLineJSON(_ url: URL) -> JSONValue? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 512 * 1024)
        let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first ?? data[...]
        return JSONValue.parse(Data(line))
    }
}

/// Rutas ya encontradas (recorrer ~/.codex/sessions entero cada vez es caro).
final class AgentStorageURLCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: URL] = [:]

    func get(_ key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ url: URL) {
        lock.lock()
        values[key] = url
        lock.unlock()
    }
}

/// Fechas ISO 8601 de los archivos de los agentes, con o sin fracciones de segundo.
enum AgentTimestamp {
    static func parse(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
