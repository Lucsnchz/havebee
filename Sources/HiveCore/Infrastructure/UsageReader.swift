import Foundation

/// Un límite de uso de la cuenta (la ventana de 5 horas o la semanal).
public struct UsageLimit: Equatable, Sendable {
    /// Duración de la ventana: 300 son 5 horas y 10080, una semana.
    public let windowMinutes: Int?
    /// Porcentaje usado, de 0 a 100.
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(windowMinutes: Int?, usedPercent: Double, resetsAt: Date?) {
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// «5h», «sem» o la cantidad de horas.
    public var label: String {
        switch windowMinutes {
        case 300?: "5h"
        case 10080?: "sem"
        case let minutes? where minutes % 1440 == 0: "\(minutes / 1440)d"
        case let minutes? where minutes >= 60: "\(minutes / 60)h"
        case let minutes?: "\(minutes)m"
        case nil: "límite"
        }
    }

    /// Para la ayuda: «5 horas», «semana».
    public var longLabel: String {
        switch windowMinutes {
        case 300?: "5 horas"
        case 10080?: "semana"
        default: label
        }
    }
}

/// Uso de una sesión: contexto ocupado y límites de la cuenta, según lo último que informó el agente.
public struct UsageSnapshot: Equatable, Sendable {
    public var agent: SessionKind
    /// Porcentaje del contexto ocupado, de 0 a 100.
    public var contextPercent: Double?
    public var limits: [UsageLimit]
    public var updatedAt: Date

    public init(agent: SessionKind, contextPercent: Double?, limits: [UsageLimit], updatedAt: Date) {
        self.agent = agent
        self.contextPercent = contextPercent
        self.limits = limits
        self.updatedAt = updatedAt
    }

    /// Los límites que todavía no se reiniciaron.
    public func activeLimits(now: Date) -> [UsageLimit] {
        limits.filter { ($0.resetsAt ?? .distantFuture) > now }
    }
}

/// Lee el uso de contexto y los límites de Claude (lo que su statusLine le pasa a Hive) y de Codex
/// (el último `token_count` de su rollout).
public enum UsageReader {
    /// Codex: el último `token_count` de los últimos 64 KB del rollout.
    public static func codex(rolloutURL: URL) -> UsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: rolloutURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 65_536 ? size - 65_536 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // Si empezamos en el medio del archivo, la primera línea está cortada.
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        let modified = (try? rolloutURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return codexSnapshot(fromLines: text, fallbackDate: modified)
    }

    public static func codexSnapshot(fromLines text: String, fallbackDate: Date) -> UsageSnapshot? {
        var context: Double?
        var limits: [UsageLimit]?
        var updatedAt: Date?
        for line in text.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
            guard let json = JSONValue.parse(String(line)), json["type"]?.string == "event_msg",
                  let payload = json["payload"], payload["type"]?.string == "token_count" else { continue }
            let lineDate = json["timestamp"]?.string.flatMap(AgentTimestamp.parse)
            if context == nil, let info = payload["info"], let window = info["model_context_window"]?.asDouble, window > 0,
               let used = info["last_token_usage"]?["total_tokens"]?.asDouble {
                context = min(max(used / window * 100, 0), 100)
                updatedAt = updatedAt ?? lineDate
            }
            if limits == nil, let rates = payload["rate_limits"], case .object = rates {
                let parsed = ["primary", "secondary"].compactMap { codexLimit(rates[$0], lineDate: lineDate ?? fallbackDate) }
                if !parsed.isEmpty {
                    limits = parsed
                    updatedAt = updatedAt ?? lineDate
                }
            }
            if context != nil && limits != nil { break }
        }
        guard context != nil || limits != nil else { return nil }
        return UsageSnapshot(agent: .codex, contextPercent: context, limits: limits ?? [], updatedAt: updatedAt ?? fallbackDate)
    }

    static func codexLimit(_ value: JSONValue?, lineDate: Date) -> UsageLimit? {
        guard let value, let used = value["used_percent"]?.asDouble else { return nil }
        let window = value["window_minutes"]?.asDouble.map { Int($0) }
        var resets = date(value["resets_at"])
        if resets == nil, let seconds = value["resets_in_seconds"]?.asDouble { resets = lineDate.addingTimeInterval(seconds) }
        return UsageLimit(windowMinutes: window, usedPercent: used, resetsAt: resets)
    }

    /// Claude: lo que guardó `hive-event claude-status` en usage/<sesión>.json.
    public static func claude(usageFile: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: usageFile), let json = JSONValue.parse(data) else { return nil }
        let modified = (try? usageFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return claudeSnapshot(json, updatedAt: modified)
    }

    public static func claudeSnapshot(_ json: JSONValue, updatedAt: Date) -> UsageSnapshot? {
        var context: Double?
        if let window = json["context_window"] {
            if let used = window["used_percentage"]?.asDouble {
                context = used
            } else if let size = window["context_window_size"]?.asDouble, size > 0, let current = window["current_usage"] {
                let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .compactMap { current[$0]?.asDouble }.reduce(0, +)
                context = tokens / size * 100
            }
        }
        var limits: [UsageLimit] = []
        for (key, minutes) in [("five_hour", 300), ("seven_day", 10080)] {
            guard let limit = json["rate_limits"]?[key],
                  let used = limit["used_percentage"]?.asDouble ?? limit["used_percent"]?.asDouble else { continue }
            limits.append(UsageLimit(windowMinutes: minutes, usedPercent: used, resetsAt: date(limit["resets_at"])))
        }
        guard context != nil || !limits.isEmpty else { return nil }
        return UsageSnapshot(agent: .claude, contextPercent: context.map { min(max($0, 0), 100) }, limits: limits, updatedAt: updatedAt)
    }

    /// Segundos (o milisegundos) desde 1970, o una fecha ISO 8601.
    static func date(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let n)?: Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        case .string(let s)?: Double(s).map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) } ?? AgentTimestamp.parse(s)
        default: nil
        }
    }

    /// «se reinicia hoy 14:00», «se reinicia mañana 9:30» o «se reinicia el jue 14:00».
    public static func resetText(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                 locale: Locale = Locale(identifier: "es")) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "se reinicia hoy \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "se reinicia mañana \(time)"
        }
        let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
        return "se reinicia el \(day.replacingOccurrences(of: ".", with: "")) \(time)"
    }
}
