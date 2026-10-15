import Foundation

/// Un mensaje leído del transcript de un agente (lo que se habló, sin herramientas ni subagentes).
public struct TranscriptMessage: Equatable, Sendable {
    /// Identifica el mensaje dentro de su conversación y no cambia entre lecturas (para no duplicarlo).
    public let key: String
    public let conversationId: String
    public let role: HistoryEntry.Role
    public let text: String
    public let date: Date?

    public init(key: String, conversationId: String, role: HistoryEntry.Role, text: String, date: Date?) {
        self.key = key
        self.conversationId = conversationId
        self.role = role
        self.text = text
        self.date = date
    }
}

/// Lee los transcripts que guardan los agentes: el de Claude (<config>/projects/<carpeta>/<id>.jsonl)
/// y el rollout de Codex (sessions/AAAA/MM/DD/rollout-…-<thread>.jsonl). Guarda lo leído en caché
/// mientras el archivo no cambie (fecha de modificación y tamaño).
public enum TranscriptReader {
    public static func read(_ url: URL, agent: SessionKind) -> [TranscriptMessage] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return [] }
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let cacheKey = "\(agent.rawValue)|\(url.standardizedFileURL.path)"
        if let cached = cache.get(cacheKey), cached.modified == modified, cached.size == size { return cached.messages }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let fallbackId = conversationId(fromFileName: url.lastPathComponent, agent: agent)
        let messages = agent == .codex ? parseCodex(text, fallbackConversationId: fallbackId)
                                       : parseClaude(text, fallbackConversationId: fallbackId)
        cache.set(cacheKey, TranscriptCache.Entry(modified: modified, size: size, messages: messages))
        return messages
    }

    /// El ID de la conversación según el nombre del archivo (<id>.jsonl o rollout-<fecha>-<thread>.jsonl).
    public static func conversationId(fromFileName name: String, agent: SessionKind) -> String {
        let base = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
        guard agent == .codex, base.hasPrefix("rollout-") else { return base }
        // rollout-2026-10-12T10-30-00-<uuid de 36 caracteres>
        return base.count > 36 ? String(base.suffix(36)) : base
    }

    // MARK: - Claude

    /// `type:user` con texto propio (sin resultados de herramientas, mensajes internos ni subagentes)
    /// y los bloques de texto de `type:assistant`.
    public static func parseClaude(_ text: String, fallbackConversationId: String) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let json = JSONValue.parse(String(line)), let type = json["type"]?.string,
                  type == "user" || type == "assistant" else { continue }
            if json["isSidechain"]?.asBool == true || json["isMeta"]?.asBool == true
                || json["isCompactSummary"]?.asBool == true || json["isVisibleInTranscriptOnly"]?.asBool == true { continue }
            let conversation = json["sessionId"]?.string ?? fallbackConversationId
            let lineKey = json["uuid"]?.string ?? "l\(index)"
            let date = json["timestamp"]?.string.flatMap(AgentTimestamp.parse)
            let content = json["message"]?["content"]
            if type == "user" {
                let raw: String?
                switch content {
                case .string(let s)?:
                    raw = s
                case .array(let blocks)?:
                    // Con un tool_result es la respuesta de una herramienta, no algo que escribiste.
                    if blocks.contains(where: { $0["type"]?.string == "tool_result" }) { continue }
                    raw = blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n\n")
                default:
                    raw = nil
                }
                guard let raw, let (role, clean) = classifyClaudeUser(raw) else { continue }
                messages.append(TranscriptMessage(key: lineKey, conversationId: conversation, role: role, text: clean, date: date))
            } else {
                guard case .array(let blocks)? = content else { continue }
                for (blockIndex, block) in blocks.enumerated() where block["type"]?.string == "text" {
                    let clean = (block["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { continue }
                    messages.append(TranscriptMessage(key: "\(lineKey)#\(blockIndex)", conversationId: conversation,
                                                      role: .assistant, text: clean, date: date))
                }
            }
        }
        return messages
    }

    /// Lo que Claude guarda como "user" pero no escribiste vos: comandos locales (/clear, !ls),
    /// recordatorios del sistema e interrupciones. Los avisos de tareas en segundo plano van como .system.
    static func classifyClaudeUser(_ raw: String) -> (HistoryEntry.Role, String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let hidden = ["<command-name>", "<command-message>", "<command-args>", "<local-command-", "<bash-input>", "<bash-stdout>",
                      "<bash-stderr>", "<system-reminder>", "<user-memory-input>", "[Request interrupted"]
        if hidden.contains(where: { text.hasPrefix($0) }) { return nil }
        if text.hasPrefix("<task-notification>") { return (.system, text) }
        return (.user, text)
    }

    // MARK: - Codex

    /// Los `response_item` de tipo `message` con rol user o assistant, sin el contexto que inyecta Codex.
    public static func parseCodex(_ text: String, fallbackConversationId: String) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        var conversation = fallbackConversationId
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let json = JSONValue.parse(String(line)), let type = json["type"]?.string else { continue }
            if type == "session_meta", let id = json["payload"]?["id"]?.string, !id.isEmpty {
                conversation = id
                continue
            }
            guard type == "response_item", let payload = json["payload"], payload["type"]?.string == "message",
                  let roleName = payload["role"]?.string, roleName == "user" || roleName == "assistant" else { continue }
            let parts = (payload["content"]?.array ?? []).compactMap { block -> String? in
                guard let kind = block["type"]?.string, ["input_text", "output_text", "text"].contains(kind) else { return nil }
                return block["text"]?.string
            }
            let clean = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if roleName == "user" && isCodexInjected(clean) { continue }
            let stamp = json["timestamp"]?.string
            let key = "\(stamp ?? "l\(index)")#\(roleName)#\(stableHash(clean))"
            messages.append(TranscriptMessage(key: key, conversationId: conversation, role: roleName == "user" ? .user : .assistant,
                                              text: clean, date: stamp.flatMap(AgentTimestamp.parse)))
        }
        return messages
    }

    /// Codex mete como mensajes "user" el contexto del entorno, las instrucciones de AGENTS.md y otros avisos.
    static func isCodexInjected(_ text: String) -> Bool {
        let prefixes = ["<environment_context>", "<user_instructions>", "<permissions instructions>", "<user_shell_command>",
                        "<turn_aborted>", "<subagent_notification>", "# AGENTS.md instructions"]
        return prefixes.contains { text.hasPrefix($0) }
    }

    /// FNV-1a de 64 bits en hexadecimal: igual en cada ejecución (a diferencia de `hashValue`).
    public static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static let cache = TranscriptCache()
}

/// Lo último leído de cada transcript, con candado porque se lee desde tareas en segundo plano.
final class TranscriptCache: @unchecked Sendable {
    struct Entry {
        let modified: Date
        let size: Int64
        let messages: [TranscriptMessage]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func get(_ key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func set(_ key: String, _ entry: Entry) {
        lock.lock()
        // Es una caché chica: con muchas sesiones abiertas alcanza con empezar de nuevo.
        if entries.count >= 48 { entries.removeAll() }
        entries[key] = entry
        lock.unlock()
    }
}
