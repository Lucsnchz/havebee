import CryptoKit
import Foundation

/// Un mensaje del historial de una sesión, o la marca de un /clear.
public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant, marker
        /// Mensaje automático que entró como prompt (tareas en segundo plano, /loop): no lo escribiste vos.
        case system
    }

    public var id: UUID
    public let date: Date
    public let role: Role
    public let text: String

    public init(id: UUID = UUID(), date: Date, role: Role, text: String) {
        self.id = id
        self.date = date
        self.role = role
        self.text = text
    }
}

/// Historial completo de cada sesión, que sobrevive a /clear.
/// Se guarda dos veces: JSONL para el panel de Hive y Markdown para que la IA lo lea.
public struct HistoryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func jsonlURL(_ sessionId: UUID) -> URL {
        directory.appendingPathComponent("\(sessionId.uuidString).jsonl")
    }

    public func markdownURL(_ sessionId: UUID) -> URL {
        directory.appendingPathComponent("\(sessionId.uuidString).md")
    }

    /// Crea el Markdown con su encabezado si todavía no existe (la IA lo busca al arrancar).
    public func ensureMarkdown(session: Session, place: String) {
        let url = markdownURL(session.id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = """
        # Historial de «\(session.name)» (\(place))

        Generado por Hive. Tiene todas las conversaciones de esta sesión, incluidas las anteriores a cada /clear.

        """
        try? header.write(to: url, atomically: true, encoding: .utf8)
    }

    public func append(_ entry: HistoryEntry, sessionId: UUID, agentName: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(entry) {
            Self.appendData(data + Data("\n".utf8), to: jsonlURL(sessionId))
        }
        Self.appendData(Data(Self.markdown(entry, agentName: agentName).utf8), to: markdownURL(sessionId))
    }

    public func load(_ sessionId: UUID) -> [HistoryEntry] {
        guard let text = try? String(contentsOf: jsonlURL(sessionId), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
    }

    /// La copia de Hive de los transcripts completos (textos intermedios incluidos).
    public func fullURL(_ sessionId: UUID) -> URL {
        directory.appendingPathComponent("\(sessionId.uuidString).full.jsonl")
    }

    /// Qué transcripts tuvo la sesión (uno por conversación: cambia con /clear o /new).
    public func segmentsURL(_ sessionId: UUID) -> URL {
        directory.appendingPathComponent("\(sessionId.uuidString).segments.json")
    }

    /// Adonde van los archivos de las sesiones eliminadas hasta que `purge` los borra.
    public var deletedDirectory: URL { directory.appendingPathComponent("deleted", isDirectory: true) }

    /// Aparta los archivos de la sesión en history/deleted/ (no a la Papelera del sistema).
    /// Quedan ahí hasta que `purge(olderThan:)` los borra.
    public func delete(_ sessionId: UUID, now: Date = Date()) {
        let fm = FileManager.default
        // Con el candado: una copia del transcript que esté terminando en segundo plano espera, y
        // después ve que la sesión se eliminó (no vuelve a crear sus archivos).
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        let files = sessionFiles(sessionId).filter { fm.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        try? fm.createDirectory(at: deletedDirectory, withIntermediateDirectories: true)
        for file in files {
            let target = deletedDirectory.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: target)
            do {
                try fm.moveItem(at: file, to: target)
                // La fecha de modificación pasa a ser la del borrado: es la que mira `purge`.
                try? fm.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
            } catch {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func sessionFiles(_ sessionId: UUID) -> [URL] {
        [jsonlURL(sessionId), markdownURL(sessionId), fullURL(sessionId), segmentsURL(sessionId)]
    }

    /// Si la sesión se eliminó (sus archivos están en history/deleted/).
    func isDeleted(_ sessionId: UUID) -> Bool {
        sessionFiles(sessionId).contains {
            FileManager.default.fileExists(atPath: deletedDirectory.appendingPathComponent($0.lastPathComponent).path)
        }
    }

    /// Borra de verdad lo eliminado hace más de `age` (30 días por defecto).
    public func purge(olderThan age: TimeInterval = 30 * 86_400, now: Date = Date()) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: deletedDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: file) }
        }
    }

    // MARK: - Transcripts completos

    /// Un transcript que tuvo la sesión: el agente, su conversación y dónde la guardó.
    public struct TranscriptSegment: Codable, Equatable, Sendable {
        public var agent: SessionKind
        public var conversationId: String
        public var path: String
        public var since: Date

        public init(agent: SessionKind, conversationId: String, path: String, since: Date) {
            self.agent = agent
            self.conversationId = conversationId
            self.path = path
            self.since = since
        }
    }

    public func transcriptSegments(_ sessionId: UUID) -> [TranscriptSegment] {
        guard let data = try? Data(contentsOf: segmentsURL(sessionId)) else { return [] }
        return (try? Self.decoder.decode([TranscriptSegment].self, from: data)) ?? []
    }

    /// Anota el transcript de la conversación actual (en history/<id>.segments.json). Si es la misma
    /// conversación que la última, solo actualiza la ruta.
    public func recordTranscript(sessionId: UUID, agent: SessionKind, conversationId: String, path: String, now: Date = Date()) {
        guard !conversationId.isEmpty, !path.isEmpty else { return }
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        guard !isDeleted(sessionId) else { return }
        var segments = transcriptSegments(sessionId)
        if let index = segments.lastIndex(where: { $0.conversationId == conversationId && $0.agent == agent }) {
            guard segments[index].path != path else { return }
            segments[index].path = path
        } else {
            segments.append(TranscriptSegment(agent: agent, conversationId: conversationId, path: path, since: now))
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(segments) { try? data.write(to: segmentsURL(sessionId), options: .atomic) }
    }

    /// Copia los textos del transcript (con TranscriptReader) a history/<id>.full.jsonl, sin repetir lo que
    /// ya estaba. Así sobreviven aunque el agente borre sus archivos. Devuelve cuántos mensajes agregó.
    @discardableResult
    public func archiveTranscript(sessionId: UUID, agent: SessionKind, path: String, now: Date = Date()) -> Int {
        let messages = TranscriptReader.read(URL(fileURLWithPath: path), agent: agent)
        guard !messages.isEmpty else { return 0 }
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        // Si la eliminaron mientras se leía el transcript, no se vuelve a crear su copia.
        guard !isDeleted(sessionId) else { return 0 }
        let known = Set(loadArchived(sessionId).map { $0.conversationId + "|" + $0.key })
        var data = Data()
        var added = 0
        var seen = known
        for message in messages where seen.insert(message.conversationId + "|" + message.key).inserted {
            let archived = ArchivedMessage(conversationId: message.conversationId, key: message.key, role: message.role,
                                           text: message.text, date: message.date ?? now)
            guard let line = try? Self.encoder.encode(archived) else { continue }
            data.append(line)
            data.append(contentsOf: Array("\n".utf8))
            added += 1
        }
        guard added > 0 else { return 0 }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.appendData(data, to: fullURL(sessionId))
        return added
    }

    /// La copia completa de Hive, como entradas del historial (con IDs que no cambian entre lecturas).
    public func loadArchive(_ sessionId: UUID) -> [HistoryEntry] {
        loadArchived(sessionId).map(\.entry)
    }

    /// La línea de tiempo completa: la copia de Hive, los transcripts vivos que se le pasen (por ejemplo,
    /// el de la conversación actual) y, del registro de siempre, los marcadores y lo que la copia no tenga.
    public func fullTimeline(_ sessionId: UUID, agent: SessionKind, live: [URL] = []) -> [HistoryEntry] {
        var full = loadArchived(sessionId)
        var seen = Set(full.map { $0.conversationId + "|" + $0.key })
        for url in live {
            for message in TranscriptReader.read(url, agent: agent) where seen.insert(message.conversationId + "|" + message.key).inserted {
                full.append(ArchivedMessage(conversationId: message.conversationId, key: message.key, role: message.role,
                                            text: message.text, date: message.date ?? .distantPast))
            }
        }
        return HistoryExport.timeline(log: load(sessionId), full: full.map(\.entry))
    }

    private func loadArchived(_ sessionId: UUID) -> [ArchivedMessage] {
        guard let text = try? String(contentsOf: fullURL(sessionId), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(ArchivedMessage.self, from: Data($0.utf8)) }
    }

    /// Una línea de history/<id>.full.jsonl.
    struct ArchivedMessage: Codable {
        let conversationId: String
        let key: String
        let role: HistoryEntry.Role
        let text: String
        let date: Date

        var entry: HistoryEntry {
            HistoryEntry(id: HistoryStore.stableId(conversationId + "|" + key), date: date, role: role, text: text)
        }
    }

    /// Un UUID que sale siempre igual del mismo texto.
    static func stableId(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Las escrituras de la copia completa y de los segmentos corren en tareas en segundo plano:
    /// el candado evita duplicados si dos llegan juntas.
    private static let writeLock = NSLock()

    // MARK: - Búsqueda

    /// Una coincidencia de la búsqueda en todas las sesiones.
    public struct SearchHit: Identifiable, Hashable, Sendable {
        public var id: String { "\(sessionId.uuidString)-\(entryId.uuidString)" }
        public let sessionId: UUID
        public let entryId: UUID
        public let role: HistoryEntry.Role
        public let date: Date
        /// ±60 caracteres alrededor de la coincidencia, en una línea.
        public let snippet: String
    }

    /// Busca en el historial guardado (el registro y la copia completa), sin distinguir tildes ni
    /// mayúsculas. Sin `sessionIds`, en todas las sesiones con historial. Lo más nuevo primero.
    public func search(_ query: String, sessionIds: [UUID]? = nil, limit: Int = 200) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, limit > 0 else { return [] }
        let ids = sessionIds ?? storedSessionIds()
        var hits: [SearchHit] = []
        for id in ids {
            let entries = HistoryExport.timeline(log: load(id), full: loadArchive(id))
            for entry in entries where entry.role != .marker {
                guard let snippet = HistoryExport.snippet(entry.text, query: q) else { continue }
                hits.append(SearchHit(sessionId: id, entryId: entry.id, role: entry.role, date: entry.date, snippet: snippet))
            }
        }
        return Array(hits.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Las sesiones que tienen historial guardado (sin las eliminadas).
    func storedSessionIds() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var ids = Set<UUID>()
        for name in names {
            let base = name.hasSuffix(".full.jsonl") ? String(name.dropLast(11)) : (name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : "")
            if let id = UUID(uuidString: base) { ids.insert(id) }
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    /// Lo que le decimos a la IA al arrancar para que sepa que el historial existe.
    public static func agentHint(markdown: URL) -> String {
        "Hive guarda el historial completo de esta sesión, incluidas las conversaciones anteriores a cada /clear, "
            + "en este archivo Markdown: \(markdown.path). No lo leas por defecto. "
            + "Si el usuario menciona algo de antes que no está en tu contexto, buscalo ahí (usá grep para encontrar la parte relevante en lugar de leerlo entero)."
    }

    static func markdown(_ entry: HistoryEntry, agentName: String) -> String {
        let when = entry.date.formatted(date: .numeric, time: .shortened)
        switch entry.role {
        case .user:
            return "\n## Vos · \(when)\n\n\(entry.text)\n"
        case .assistant:
            return "\n## \(agentName) · \(when)\n\n\(entry.text)\n"
        case .system:
            return "\n## Aviso automático · \(when)\n\n\(entry.text)\n"
        case .marker:
            return "\n---\n\n> **\(entry.text) · \(when)**: \(markerMeaning(entry.text))\n\n---\n"
        }
    }

    /// Qué significa cada marcador: /clear y «Nueva conversación» empiezan de cero, /compact no.
    public static func markerMeaning(_ text: String) -> String {
        if text == "/compact" {
            return "Se compactó el contexto. La IA sigue con un resumen de lo anterior."
        }
        if text.hasPrefix(AgentEventInterpreter.stopFailureMarker) {
            return "El turno se cortó por un error. Lo de arriba sigue en la memoria de la IA."
        }
        return "Desde acá la IA arrancó con el contexto limpio. Lo de arriba ya no está en su memoria."
    }

    private static func appendData(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
