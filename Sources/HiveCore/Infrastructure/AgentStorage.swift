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
        let base = claudeConfigDir.appendingPathComponent("projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return false }
        return dirs.contains { dir in
            FileManager.default.fileExists(atPath: base.appendingPathComponent(dir).appendingPathComponent("\(id).jsonl").path)
        }
    }

    /// El `notify` que ya tenías en el config.toml de Codex (para seguir llamándolo).
    public func codexExistingNotify() -> [String]? {
        guard let text = try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8) else { return nil }
        return CodexNotify.existing(inConfig: text)
    }

    /// Plan B para reanudar Codex: si nunca llegó un thread-id (por ejemplo, cortaste el primer turno),
    /// buscamos el archivo de sesión que Codex creó en esa carpeta después del último arranque.
    public func discoverCodexThread(cwd: String, since: Date, excluding: Set<String>, now: Date = Date()) -> String? {
        let fm = FileManager.default
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: since.addingTimeInterval(-86_400))
        let threshold = since.addingTimeInterval(-5)
        var best: (date: Date, id: String)?
        while day <= now {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = codexHome.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= threshold,
                      let meta = Self.firstLineJSON(file),
                      let id = meta["payload"]?["id"]?.string,
                      let sessionDir = meta["payload"]?["cwd"]?.string,
                      samePath(sessionDir, cwd),
                      !excluding.contains(id) else { continue }
                if best == nil || modified > best!.date { best = (modified, id) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return best?.id
    }

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
