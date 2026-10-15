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

    public func delete(_ sessionId: UUID) {
        try? FileManager.default.removeItem(at: jsonlURL(sessionId))
        try? FileManager.default.removeItem(at: markdownURL(sessionId))
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
