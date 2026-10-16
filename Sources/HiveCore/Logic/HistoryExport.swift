import Foundation

/// Lógica del panel de historial que no depende de la vista: copiar, buscar, armar la línea de tiempo
/// y partir el Markdown en texto y bloques de código.
public enum HistoryExport {
    /// Todo el historial como texto: «Vos: …», «Claude Code: …» y las divisorias de /clear,
    /// separados por una línea en blanco.
    public static func plainText(_ entries: [HistoryEntry], agent: String) -> String {
        entries.map { plainText($0, agent: agent) }.joined(separator: "\n\n")
    }

    public static func plainText(_ entry: HistoryEntry, agent: String) -> String {
        switch entry.role {
        case .user: return "Vos: \(entry.text)"
        case .assistant: return "\(agent): \(entry.text)"
        case .system: return "Aviso automático: \(entry.text)"
        case .marker:
            // Un corte, con la frase clara y el código de la API entre paréntesis.
            let marker = HistoryStore.markerTitle(entry.text)
            return "—— \(marker.title)\(marker.code.map { " (\($0))" } ?? "") ——"
        }
    }

    /// Los mensajes que contienen la búsqueda, sin distinguir mayúsculas ni tildes.
    /// Las divisorias se conservan para no perder dónde se limpió el contexto.
    public static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.role == .marker || matches($0.text, query: q) }
    }

    public static func matches(_ text: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Un fragmento de ±`radius` caracteres alrededor de la primera coincidencia, en una sola línea.
    public static func snippet(_ text: String, query: String, radius: Int = 60) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let match = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let flat = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + flat + (end < text.endIndex ? "…" : "")
    }

    /// Un texto sin las marcas de Markdown que en una fila se verían crudas: títulos («## »), viñetas
    /// (pasan a «• »), negritas («**así**») y código («`así`» y «```php»). Va antes de juntar las
    /// líneas: los títulos y las viñetas solo cuentan al principio de una línea, así que un « - » en
    /// medio de una («$precio - $descuento») queda como está. Los «_» también: son parte de nombres
    /// como `rate_limit` o `__construct`.
    public static func withoutMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^([ \t]*)#{1,6}[ \t]+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^([ \t]*)[-*+][ \t]+"#, with: "$1• ", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*(\S(?:.*?\S)?)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"```[A-Za-z0-9_+-]*\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
    }

    /// Junta la copia completa (textos intermedios de los transcripts) con el registro de Hive:
    /// del registro quedan los marcadores, los avisos y lo que la copia no tenga (lo anterior a ella).
    public static func timeline(log: [HistoryEntry], full: [HistoryEntry]) -> [HistoryEntry] {
        guard !full.isEmpty else { return log }
        func normalized(_ role: HistoryEntry.Role, _ text: String) -> String {
            role.rawValue + "|" + text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var covered = Set<String>()
        // La respuesta final de un turno puede venir partida en varios bloques seguidos: se cubren
        // también las uniones de hasta 6 bloques consecutivos.
        var run: [String] = []
        func flush() {
            for start in run.indices {
                for end in (start + 1)..<min(start + 6, run.count) {
                    covered.insert(normalized(.assistant, run[start...end].joined(separator: " ")))
                }
            }
            run = []
        }
        let orderedFull = full.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        for entry in orderedFull {
            covered.insert(normalized(entry.role, entry.text))
            if entry.role == .assistant { run.append(entry.text) } else { flush() }
        }
        flush()
        let kept = log.filter { $0.role == .marker || !covered.contains(normalized($0.role, $0.text)) }
        // A igual fecha, primero la copia completa y después el registro.
        return (orderedFull + kept).enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
    }

    /// La entrada de `candidates` que corresponde a `target`. La búsqueda global devuelve entradas del
    /// registro de los hooks, pero en la línea de tiempo completa el mismo mensaje puede venir de la
    /// copia del transcript (con otro ID): se busca el del mismo rol y texto y, si no hay (una respuesta
    /// final partida en varios bloques), el del mismo rol más cercano en el tiempo.
    public static func counterpart(of target: HistoryEntry, in candidates: [HistoryEntry]) -> UUID? {
        if candidates.contains(where: { $0.id == target.id }) { return target.id }
        func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let text = flat(target.text)
        if let same = candidates.first(where: { $0.role == target.role && flat($0.text) == text }) { return same.id }
        let sameRole = candidates.filter { $0.role == target.role }
        let pool = sameRole.isEmpty ? candidates : sameRole
        return pool.min { abs($0.date.timeIntervalSince(target.date)) < abs($1.date.timeIntervalSince(target.date)) }?.id
    }

    // MARK: - Markdown

    /// Un pedazo del texto de una respuesta: prosa (Markdown en línea) o un bloque ``` de código.
    public enum Block: Equatable, Sendable {
        case prose(String)
        case code(language: String?, code: String)
    }

    /// Separa los bloques ``` (o ~~~) del resto. Un bloque sin cerrar llega hasta el final.
    public static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [Substring] = []
        var code: [Substring]?
        var fence = ""
        var language: String?
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix(fence) && trimmed.trimmingCharacters(in: CharacterSet(charactersIn: fence.prefix(1).description)).isEmpty {
                    blocks.append(.code(language: language, code: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                let mark = trimmed.first ?? "`"
                fence = String(trimmed.prefix { $0 == mark })
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                language = info.isEmpty ? nil : String(info.split(separator: " ").first ?? "")
                code = []
            } else {
                prose.append(line)
            }
        }
        if let lines = code { blocks.append(.code(language: language, code: lines.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }

    // MARK: - Fechas

    /// Separador de día: «Hoy», «Ayer», «21 sept» (con el año si no es este).
    public static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                locale: Locale = Locale(identifier: "es")) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Hoy" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Ayer" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }
}
