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
        // Las vistas hacen Int(usedPercent): un NaN o un 1e20 de afuera haría caer a Hive.
        self.usedPercent = UsageReader.percent(usedPercent) ?? 0
        self.resetsAt = resetsAt
    }

    /// Al lado de la barrita: «5 h», «semana», «1 día». Sin abreviaturas que haya que adivinar («sem»).
    public var label: String {
        switch windowMinutes {
        case 10080?: "semana"
        case let minutes? where minutes > 0 && minutes % 1440 == 0: Self.days(minutes)
        case let minutes? where minutes > 0 && minutes % 60 == 0: "\(minutes / 60) h"
        case let minutes? where minutes > 0: "\(minutes) min"
        default: "límite"
        }
    }

    /// Para la ayuda y el detalle: «5 horas», «semana», «1 día».
    public var longLabel: String {
        switch windowMinutes {
        case 10080?: "semana"
        case let minutes? where minutes > 0 && minutes % 1440 == 0: Self.days(minutes)
        case let minutes? where minutes > 0 && minutes % 60 == 0: minutes == 60 ? "1 hora" : "\(minutes / 60) horas"
        case let minutes? where minutes > 0: minutes == 1 ? "1 minuto" : "\(minutes) minutos"
        default: "límite"
        }
    }

    private static func days(_ minutes: Int) -> String {
        minutes == 1440 ? "1 día" : "\(minutes / 1440) días"
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
        self.contextPercent = contextPercent.flatMap(UsageReader.percent)
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
    /// Un porcentaje que viene de afuera, acotado a 0…100. Lo que no es un número finito (NaN, inf) no cuenta.
    public static func percent(_ value: Double) -> Double? {
        value.isFinite ? min(max(value, 0), 100) : nil
    }

    /// Codex: el último `token_count` del rollout, buscado desde el final. Casi siempre está en los
    /// últimos KB, pero mientras corre un comando con mucha salida puede quedar decenas de MB atrás:
    /// el archivo se recorre hacia atrás de a pedazos, sin cargarlo entero, hasta `maxScan` bytes.
    public static func codex(rolloutURL: URL, maxScan: Int = 64 << 20) -> UsageSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: rolloutURL) else { return nil }
        defer { try? handle.close() }
        let modified = (try? rolloutURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        var usage = CodexUsage(fallbackDate: modified)
        let marker = Data(#""token_count""#.utf8)
        ReverseLines.scan(handle, maxBytes: maxScan) { line in
            if line.range(of: marker, in: line.startIndex..<line.endIndex) != nil { usage.add(line) }
            return usage.isComplete
        }
        return usage.snapshot
    }

    public static func codexSnapshot(fromLines text: String, fallbackDate: Date) -> UsageSnapshot? {
        var usage = CodexUsage(fallbackDate: fallbackDate)
        for line in text.split(separator: "\n").reversed() where line.contains("\"token_count\"") {
            usage.add(Data(line.utf8))
            if usage.isComplete { break }
        }
        return usage.snapshot
    }

    /// Junta, de la línea más nueva a la más vieja, el último contexto y los últimos límites de Codex.
    struct CodexUsage {
        let fallbackDate: Date
        var context: Double?
        var limits: [UsageLimit]?
        var updatedAt: Date?
        /// Cuántos token_count se miraron.
        var examined = 0

        /// Sin límites en los últimos token_count (con una API key, `rate_limits` viene siempre en null)
        /// no tiene sentido seguir hasta el principio de un rollout de decenas de MB cada 30 s.
        static let limitsLookback = 20

        init(fallbackDate: Date) {
            self.fallbackDate = fallbackDate
        }

        var isComplete: Bool { context != nil && (limits != nil || examined >= Self.limitsLookback) }

        mutating func add(_ line: Data) {
            guard let json = JSONValue.parse(line), json["type"]?.string == "event_msg",
                  let payload = json["payload"], payload["type"]?.string == "token_count" else { return }
            examined += 1
            let lineDate = json["timestamp"]?.string.flatMap(AgentTimestamp.parse)
            if context == nil, let info = payload["info"], let window = info["model_context_window"]?.asDouble, window > 0,
               let used = info["last_token_usage"]?["total_tokens"]?.asDouble {
                context = UsageReader.percent(used / window * 100)
                updatedAt = updatedAt ?? lineDate
            }
            if limits == nil, let rates = payload["rate_limits"], case .object = rates {
                let parsed = ["primary", "secondary"].compactMap { UsageReader.codexLimit(rates[$0], lineDate: lineDate ?? fallbackDate) }
                if !parsed.isEmpty {
                    limits = parsed
                    updatedAt = updatedAt ?? lineDate
                }
            }
        }

        var snapshot: UsageSnapshot? {
            guard context != nil || limits != nil else { return nil }
            return UsageSnapshot(agent: .codex, contextPercent: context, limits: limits ?? [], updatedAt: updatedAt ?? fallbackDate)
        }
    }

    static func codexLimit(_ value: JSONValue?, lineDate: Date) -> UsageLimit? {
        guard let value, let used = value["used_percent"]?.asDouble.flatMap(percent) else { return nil }
        // Int(_:) se cae con un número fuera de rango: lo que no es una duración razonable se ignora.
        let window = value["window_minutes"]?.asDouble.flatMap { $0.isFinite && $0 >= 0 && $0 < 1e9 ? Int($0) : nil }
        var resets = date(value["resets_at"])
        if resets == nil, let seconds = value["resets_in_seconds"]?.asDouble, seconds.isFinite, abs(seconds) < 1e10 {
            resets = lineDate.addingTimeInterval(seconds)
        }
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
                  let used = (limit["used_percentage"]?.asDouble ?? limit["used_percent"]?.asDouble).flatMap(percent) else { continue }
            limits.append(UsageLimit(windowMinutes: minutes, usedPercent: used, resetsAt: date(limit["resets_at"])))
        }
        guard context != nil || !limits.isEmpty else { return nil }
        return UsageSnapshot(agent: .claude, contextPercent: context.flatMap(percent), limits: limits, updatedAt: updatedAt)
    }

    /// Segundos (o milisegundos) desde 1970, o una fecha ISO 8601.
    static func date(_ value: JSONValue?) -> Date? {
        func epoch(_ n: Double) -> Date? {
            guard n.isFinite, abs(n) < 1e15 else { return nil }
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        switch value {
        case .number(let n)?: return epoch(n)
        case .string(let s)?: return Double(s).map(epoch) ?? AgentTimestamp.parse(s)
        default: return nil
        }
    }

    /// «se reinicia hoy 14:00», «se reinicia mañana 9:30» o «se reinicia el jueves 14:00».
    public static func resetText(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                 locale: Locale = Locale(identifier: "es")) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "se reinicia hoy \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "se reinicia mañana \(time)"
        }
        // El día entero («el jueves»): «el jue» parecía cortado.
        let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
        return "se reinicia el \(day) \(time)"
    }
}

/// Recorre las líneas de un archivo de la última a la primera, leyendo de a pedazos desde el final.
enum ReverseLines {
    /// Llama a `visit` con cada línea completa (sin el salto), de atrás hacia adelante, hasta que
    /// devuelva true o se hayan recorrido `maxBytes`.
    static func scan(_ handle: FileHandle, maxBytes: Int, chunk: Int = 1 << 20, visit: (Data) -> Bool) {
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        let floor = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        var end = size
        // El principio de la línea que empezó en el pedazo anterior (más atrás en el archivo).
        var carry = Data()
        while end > floor {
            let start = end - min(UInt64(chunk), end - floor)
            guard (try? handle.seek(toOffset: start)) != nil,
                  let piece = try? handle.read(upToCount: Int(end - start)), !piece.isEmpty else { return }
            var buffer = piece
            buffer.append(carry)
            // Los saltos de línea del pedazo, para cortar las líneas sin recorrerlas dos veces.
            var newlines: [Int] = []
            buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count, let found = memchr(base + offset, 10, raw.count - offset) {
                    let index = base.distance(to: UnsafeRawPointer(found))
                    newlines.append(index)
                    offset = index + 1
                }
            }
            var lineEnd = buffer.count
            for newline in newlines.reversed() {
                let line = buffer[(newline + 1)..<lineEnd]
                if !line.isEmpty, visit(Data(line)) { return }
                lineEnd = newline
            }
            carry = Data(buffer[0..<lineEnd])
            end = start
        }
        // Lo que quedó es una línea entera solo si llegamos al principio del archivo.
        if floor == 0, !carry.isEmpty { _ = visit(carry) }
    }
}
