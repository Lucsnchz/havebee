import CryptoKit
import Foundation

/// Dónde guardan sus conversaciones Claude, Codex, Gemini y Grok, para poder reanudarlas.
/// Las carpetas se inyectan para que los tests usen carpetas temporales.
public struct AgentStorage: Sendable {
    public let claudeConfigDir: URL
    public let codexHome: URL
    public let geminiHome: URL
    /// La carpeta de Grok Build (~/.grok): sus sesiones y sus hooks personales.
    public let grokHome: URL

    /// Sin `grokHome`, va al lado de la de Gemini (en los tests, dentro de la misma carpeta temporal).
    public init(claudeConfigDir: URL, codexHome: URL, geminiHome: URL, grokHome: URL? = nil) {
        self.claudeConfigDir = claudeConfigDir
        self.codexHome = codexHome
        self.geminiHome = geminiHome
        self.grokHome = grokHome ?? geminiHome.deletingLastPathComponent().appendingPathComponent("grok", isDirectory: true)
    }

    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentStorage {
        func dir(_ key: String, default path: String) -> URL {
            if let value = environment[key], !value.isEmpty { return URL(fileURLWithPath: value) }
            return home.appendingPathComponent(path)
        }
        return AgentStorage(claudeConfigDir: dir("CLAUDE_CONFIG_DIR", default: ".claude"),
                            codexHome: dir("CODEX_HOME", default: ".codex"),
                            geminiHome: home.appendingPathComponent(".gemini"),
                            grokHome: home.appendingPathComponent(".grok"))
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
        codexNotifyStatus().command
    }

    /// El `notify` de Codex y si existe pero no lo pudimos leer (Ajustes lo avisa: no se va a llamar).
    public func codexNotifyStatus() -> (command: [String]?, unreadable: Bool) {
        let file = codexHome.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: file.path) else { return (nil, false) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return (nil, true) }
        switch TOML.topLevelStringArray("notify", in: text) {
        case .found(let command): return (command, false)
        case .unreadable: return (nil, true)
        case .missing: return (nil, false)
        }
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

    /// Una conversación persistida del usuario en esta carpeta, no una tarea interna ni un subagente.
    public func isCodexConversation(_ id: String, in directory: String) -> Bool {
        guard let url = codexRolloutURL(id), let meta = Self.firstLineJSON(url),
              let payload = meta["payload"], payload["id"]?.string == id,
              let cwd = payload["cwd"]?.string, samePath(cwd, directory),
              !Self.isSubagentMeta(payload) else { return false }
        return payload["source"]?.string == "cli"
    }

    /// El archivo de un thread de Codex: sessions/AAAA/MM/DD/rollout-<fecha>-<thread>.jsonl
    /// (o archived_sessions/ si lo archivaste).
    ///
    /// Se consulta desde el hilo principal con cada aviso de un thread nuevo (`isCodexSubagentThread`),
    /// así que primero mira solo la carpeta del día: los IDs de Codex son UUID v7 y traen la fecha en
    /// que se crearon. Recorrer sessions/ entero (miles de rollouts) queda para los IDs que no la traen.
    public func codexRolloutURL(_ threadId: String) -> URL? {
        guard !threadId.isEmpty else { return nil }
        let key = codexHome.path + "|" + threadId
        if let cached = Self.rolloutCache.get(key), FileManager.default.fileExists(atPath: cached.path) { return cached }
        let suffix = "-\(threadId).jsonl"
        let fm = FileManager.default
        var folders: [URL] = []
        if let created = Self.uuidV7Date(threadId) {
            // La carpeta usa la fecha local de Codex: el día de antes y el de después cubren cualquier huso.
            let calendar = Calendar.current
            for offset in [0, -1, 1] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: created) else { continue }
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                folders.append(codexHome.appendingPathComponent(
                    String(format: "sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)))
            }
        }
        folders.append(codexHome.appendingPathComponent("archived_sessions"))
        for folder in folders {
            guard let name = (try? fm.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(suffix) }) else { continue }
            let file = folder.appendingPathComponent(name)
            Self.rolloutCache.set(key, file)
            return file
        }
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

    /// La fecha de creación de un UUID v7 (los primeros 48 bits son milisegundos desde 1970).
    /// nil si el texto no es un UUID o es de otra versión.
    static func uuidV7Date(_ id: String) -> Date? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let b = uuid.uuid
        guard b.6 >> 4 == 7 else { return nil }
        let ms = [b.0, b.1, b.2, b.3, b.4, b.5].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
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
    /// (<home>/tmp/<hash>/chats/*.json) después del último arranque. Gana el que empezó (startTime)
    /// más cerca del arranque, no el último modificado. Si no hay, arranca de cero.
    public func discoverGeminiSession(cwd: String, since: Date, excluding: Set<String>) -> String? {
        let fm = FileManager.default
        let base = geminiHome.appendingPathComponent("tmp")
        let hash = Self.sha256(URL(fileURLWithPath: cwd).standardizedFileURL.path)
        let threshold = since.addingTimeInterval(-5)
        var best: (distance: TimeInterval, id: String)?
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
                let started = json["startTime"]?.string.flatMap(AgentTimestamp.parse) ?? modified
                guard started >= threshold else { continue }
                let distance = abs(started.timeIntervalSince(since))
                if best == nil || distance < best!.distance { best = (distance, id) }
            }
        }
        return best?.id
    }

    // MARK: - Grok

    /// Grok Build guarda cada sesión en una carpeta con su ID, agrupada por directorio de trabajo
    /// (<home>/sessions/<carpeta>/<id>/ con summary.json y updates.jsonl). Si no está, la sesión nunca
    /// recibió un mensaje y hay que arrancarla de cero con --session-id. Se busca por nombre, sin
    /// depender de cómo arma Grok el nombre de la carpeta del directorio.
    public func grokSessionExists(_ id: String) -> Bool {
        let id = id.lowercased()
        guard !id.isEmpty else { return false }
        let fm = FileManager.default
        let base = grokHome.appendingPathComponent("sessions")
        func contains(_ dir: URL, depth: Int) -> Bool {
            guard depth > 0, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
            if names.contains(where: { $0.lowercased() == id || $0.lowercased().hasPrefix(id + ".") }) { return true }
            return names.prefix(2000).contains { name in
                var isDirectory: ObjCBool = false
                let child = dir.appendingPathComponent(name)
                return fm.fileExists(atPath: child.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    && contains(child, depth: depth - 1)
            }
        }
        return contains(base, depth: 3)
    }

    /// Los hooks de Grok Build no se pueden pasar al lanzarlo: se instalan como hooks personales
    /// (<home>/hooks/hive.json). Llaman al puente solo dentro de Hive (afuera, `HIVE_EVENT_BIN` no
    /// existe y corren `true`). Solo escribe si el archivo cambió. Devuelve el error, si hubo.
    @discardableResult
    public func installGrokHooks() -> String? {
        let file = grokHome.appendingPathComponent("hooks").appendingPathComponent("hive.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: EventBridge.grokHooks.anyValue,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if (try? Data(contentsOf: file)) == data { return nil }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
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
