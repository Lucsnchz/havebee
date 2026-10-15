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
/// y el rollout de Codex (sessions/AAAA/MM/DD/rollout-…-<thread>.jsonl).
///
/// Esos archivos llegan a pesar cientos de MB (Claude guarda cada pedido a la API y cada resultado de
/// herramienta), y el panel los vuelve a leer mientras el agente trabaja. Por eso se leen de a pedazos,
/// se descartan las líneas que no interesan sin parsearlas enteras y, como los agentes solo agregan al
/// final, la lectura siguiente sigue desde donde quedó la anterior.
public enum TranscriptReader {
    public static func read(_ url: URL, agent: SessionKind) -> [TranscriptMessage] {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return [] }
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let cacheKey = "\(agent.rawValue)|\(path)"
        let cached = cache.get(cacheKey)
        if let cached, cached.fileNumber == fileNumber, cached.modified == modified, cached.size == size { return cached.messages }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        var progress = Progress(conversation: conversationId(fromFileName: url.lastPathComponent, agent: agent))
        // Si es el mismo archivo y lo ya leído sigue igual, solo falta lo que se agregó.
        if let cached, cached.fileNumber == fileNumber, cached.progress.offset <= size,
           Self.stillStartsWith(handle, cached.progress) {
            progress = cached.progress
        }
        guard let tail = scan(handle, agent: agent, progress: &progress) else { return [] }
        let messages = progress.committed + tail
        cache.set(cacheKey, TranscriptCache.Entry(modified: modified, size: size, fileNumber: fileNumber,
                                                  progress: progress, messages: messages))
        return messages
    }

    /// El ID de la conversación según el nombre del archivo (<id>.jsonl o rollout-<fecha>-<thread>.jsonl).
    public static func conversationId(fromFileName name: String, agent: SessionKind) -> String {
        let base = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
        guard agent == .codex, base.hasPrefix("rollout-") else { return base }
        // rollout-2026-10-12T10-30-00-<uuid de 36 caracteres>
        return base.count > 36 ? String(base.suffix(36)) : base
    }

    // MARK: - Lectura incremental

    /// Hasta dónde se leyó un archivo: las líneas completas ya procesadas y lo que salió de ellas.
    struct Progress {
        /// Bytes leídos hasta el último salto de línea.
        var offset: UInt64 = 0
        /// Líneas no vacías procesadas (sirven de clave cuando una línea no trae su ID).
        var lineIndex = 0
        /// La conversación en curso (en Codex la define el session_meta).
        var conversation: String
        var committed: [TranscriptMessage] = []
        /// Los últimos bytes antes de `offset`, para darse cuenta si el archivo se reescribió.
        var signature = Data()

        init(conversation: String) {
            self.conversation = conversation
        }
    }

    static let chunkSize = 4 << 20

    /// Procesa las líneas completas desde `progress.offset` y deja `progress` al día. Devuelve lo que sale
    /// de la última línea si todavía no terminó con un salto (puede estar a medio escribir, así que no
    /// cuenta como leída), o nil si no se pudo leer.
    static func scan(_ handle: FileHandle, agent: SessionKind, progress: inout Progress) -> [TranscriptMessage]? {
        do {
            try handle.seek(toOffset: progress.offset)
        } catch {
            return nil
        }
        var buffer = Data()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            var lineStart = 0
            while let newline = newlineIndex(in: buffer, from: lineStart) {
                let line = buffer[lineStart..<newline]
                if !line.isEmpty {
                    progress.committed += messages(line: line, index: progress.lineIndex, agent: agent, conversation: &progress.conversation)
                    progress.lineIndex += 1
                }
                lineStart = newline + 1
            }
            progress.offset += UInt64(lineStart)
            buffer = Data(buffer[lineStart...])
        }
        if progress.offset > 0 {
            let length = min(UInt64(signatureLength), progress.offset)
            progress.signature = (try? read(handle, at: progress.offset - length, count: Int(length))) ?? Data()
        }
        guard !buffer.isEmpty else { return [] }
        var conversation = progress.conversation
        return messages(line: buffer[...], index: progress.lineIndex, agent: agent, conversation: &conversation)
    }

    /// El próximo salto de línea (`buffer` siempre empieza en el índice 0).
    private static func newlineIndex(in buffer: Data, from start: Int) -> Int? {
        buffer.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress, start < raw.count, let found = memchr(base + start, 10, raw.count - start) else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
    }

    static let signatureLength = 64

    /// Si el archivo sigue empezando con lo que ya se leyó (los agentes solo agregan al final).
    static func stillStartsWith(_ handle: FileHandle, _ progress: Progress) -> Bool {
        guard progress.offset > 0 else { return true }
        let length = UInt64(progress.signature.count)
        guard length > 0, length <= progress.offset else { return false }
        return (try? read(handle, at: progress.offset - length, count: Int(length))) == progress.signature
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    static func messages(line: Data.SubSequence, index: Int, agent: SessionKind, conversation: inout String) -> [TranscriptMessage] {
        agent == .codex ? codexMessages(line: line, index: index, conversation: &conversation)
                        : claudeMessages(line: line, index: index, fallbackConversationId: conversation)
    }

    // MARK: - Claude

    /// `type:user` con texto propio (sin resultados de herramientas, mensajes internos ni subagentes)
    /// y los bloques de texto de `type:assistant`.
    public static func parseClaude(_ text: String, fallbackConversationId: String) -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            messages += claudeMessages(line: Data(line.utf8)[...], index: index, fallbackConversationId: fallbackConversationId)
        }
        return messages
    }

    static func claudeMessages(line: Data.SubSequence, index: Int, fallbackConversationId: String) -> [TranscriptMessage] {
        // Antes de parsear: la mayor parte del archivo son pedidos a la API, resultados de herramientas
        // y otros registros internos que nunca van al historial.
        if let type = JSONLine.topLevelString("type", in: line) {
            guard type == "user" || type == "assistant" else { return [] }
            if type == "user" && JSONLine.has(JSONLine.toolResult, in: line) { return [] }
            if type == "assistant" && JSONLine.has(JSONLine.toolUse, in: line) && !JSONLine.has(JSONLine.textBlock, in: line) { return [] }
        }
        guard let json = JSONValue.parse(Data(line)), let type = json["type"]?.string,
              type == "user" || type == "assistant" else { return [] }
        if json["isSidechain"]?.asBool == true || json["isMeta"]?.asBool == true
            || json["isCompactSummary"]?.asBool == true || json["isVisibleInTranscriptOnly"]?.asBool == true { return [] }
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
                if blocks.contains(where: { $0["type"]?.string == "tool_result" }) { return [] }
                raw = blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n\n")
            default:
                raw = nil
            }
            guard let raw, let (role, clean) = classifyClaudeUser(raw) else { return [] }
            return [TranscriptMessage(key: lineKey, conversationId: conversation, role: role, text: clean, date: date)]
        }
        guard case .array(let blocks)? = content else { return [] }
        var messages: [TranscriptMessage] = []
        for (blockIndex, block) in blocks.enumerated() where block["type"]?.string == "text" {
            let clean = (block["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            messages.append(TranscriptMessage(key: "\(lineKey)#\(blockIndex)", conversationId: conversation,
                                              role: .assistant, text: clean, date: date))
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
            messages += codexMessages(line: Data(line.utf8)[...], index: index, conversation: &conversation)
        }
        return messages
    }

    static func codexMessages(line: Data.SubSequence, index: Int, conversation: inout String) -> [TranscriptMessage] {
        // Las salidas de los comandos y el razonamiento cifrado ocupan casi todo el rollout.
        if let type = JSONLine.topLevelString("type", in: line) {
            guard type == "session_meta" || (type == "response_item" && JSONLine.has(JSONLine.message, in: line)) else { return [] }
        }
        guard let json = JSONValue.parse(Data(line)), let type = json["type"]?.string else { return [] }
        if type == "session_meta", let id = json["payload"]?["id"]?.string, !id.isEmpty {
            conversation = id
            return []
        }
        guard type == "response_item", let payload = json["payload"], payload["type"]?.string == "message",
              let roleName = payload["role"]?.string, roleName == "user" || roleName == "assistant" else { return [] }
        let parts = (payload["content"]?.array ?? []).compactMap { block -> String? in
            guard let kind = block["type"]?.string, ["input_text", "output_text", "text"].contains(kind) else { return nil }
            return block["text"]?.string
        }
        let clean = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        if roleName == "user" && isCodexInjected(clean) { return [] }
        let stamp = json["timestamp"]?.string
        let key = "\(stamp ?? "l\(index)")#\(roleName)#\(stableHash(clean))"
        return [TranscriptMessage(key: key, conversationId: conversation, role: roleName == "user" ? .user : .assistant,
                                  text: clean, date: stamp.flatMap(AgentTimestamp.parse))]
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

/// Mirar una línea JSON sin parsearla entera.
enum JSONLine {
    /// Marcas que, sin espacios y fuera de un texto (ahí las comillas van escapadas), solo aparecen
    /// como estructura. Si el agente escribiera el JSON con espacios no coincidirían y la línea se
    /// parsearía igual: nunca hacen perder un mensaje.
    static let toolResult = Data(#""type":"tool_result""#.utf8)
    static let toolUse = Data(#""type":"tool_use""#.utf8)
    static let textBlock = Data(#""type":"text""#.utf8)
    /// `"message"` como texto o clave de JSON (con o sin espacios alrededor).
    static let message = Data(#""message""#.utf8)

    static func has(_ needle: Data, in line: Data.SubSequence) -> Bool {
        line.range(of: needle, in: line.startIndex..<line.endIndex) != nil
    }

    /// El valor de una clave de primer nivel, si es un texto sin escapes. nil si no está, si no es un
    /// texto o si la línea no tiene la forma esperada (entonces conviene parsearla entera).
    static func topLevelString(_ key: String, in line: Data.SubSequence) -> String? {
        let wanted = Array(key.utf8)
        return line.withUnsafeBytes { bytes -> String? in
            let count = bytes.count
            var i = 0
            func skipSpaces() {
                while i < count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0D || bytes[i] == 0x0A { i += 1 }
            }
            /// Deja `i` después de la comilla de cierre. Devuelve el rango del contenido y si tenía escapes.
            func skipString() -> (Range<Int>, Bool)? {
                guard i < count, bytes[i] == 0x22 else { return nil }
                i += 1
                let start = i
                var escaped = false
                while i < count {
                    switch bytes[i] {
                    case 0x5C:
                        escaped = true
                        i += 2
                    case 0x22:
                        let range = start..<i
                        i += 1
                        return (range, escaped)
                    default:
                        i += 1
                    }
                }
                return nil
            }
            func skipValue() -> Bool {
                guard i < count else { return false }
                switch bytes[i] {
                case 0x22:
                    return skipString() != nil
                case 0x7B, 0x5B:
                    var depth = 0
                    while i < count {
                        switch bytes[i] {
                        case 0x22:
                            guard skipString() != nil else { return false }
                            continue
                        case 0x7B, 0x5B:
                            depth += 1
                        case 0x7D, 0x5D:
                            depth -= 1
                            if depth == 0 {
                                i += 1
                                return true
                            }
                        default:
                            break
                        }
                        i += 1
                    }
                    return false
                default:
                    // Número, true, false o null.
                    let start = i
                    while i < count, bytes[i] != 0x2C, bytes[i] != 0x7D, bytes[i] != 0x5D,
                          bytes[i] != 0x20, bytes[i] != 0x0A, bytes[i] != 0x0D, bytes[i] != 0x09 { i += 1 }
                    return i > start
                }
            }
            skipSpaces()
            guard i < count, bytes[i] == 0x7B else { return nil }
            i += 1
            while true {
                skipSpaces()
                guard let (keyRange, _) = skipString() else { return nil }
                skipSpaces()
                guard i < count, bytes[i] == 0x3A else { return nil }
                i += 1
                skipSpaces()
                if keyRange.count == wanted.count, zip(keyRange, wanted).allSatisfy({ bytes[$0] == $1 }) {
                    guard let (valueRange, escaped) = skipString(), !escaped else { return nil }
                    return String(decoding: bytes[valueRange], as: UTF8.self)
                }
                guard skipValue() else { return nil }
                skipSpaces()
                guard i < count else { return nil }
                if bytes[i] == 0x2C {
                    i += 1
                } else {
                    // `}`: la clave no está.
                    return nil
                }
            }
        }
    }
}

/// Lo último leído de cada transcript, con candado porque se lee desde tareas en segundo plano.
final class TranscriptCache: @unchecked Sendable {
    struct Entry {
        let modified: Date
        let size: UInt64
        let fileNumber: UInt64
        let progress: TranscriptReader.Progress
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
        if entries.count >= 48 && entries[key] == nil { entries.removeAll() }
        entries[key] = entry
        lock.unlock()
    }
}
