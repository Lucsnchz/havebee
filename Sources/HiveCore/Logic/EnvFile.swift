import Foundation

/// Cambios puntuales en un archivo .env sin tocar el resto: conserva comillas, comentarios,
/// `export`, líneas en blanco y el orden.
public enum EnvFile {
    /// Claves que suelen repetir el host de APP_URL en Laravel.
    public static let hostKeys = ["SESSION_DOMAIN", "SANCTUM_STATEFUL_DOMAINS"]

    /// Partes de una línea `KEY=valor # comentario`.
    private struct Entry {
        var lead: String      // espacios y "export "
        var key: String
        var equals: String    // "=" con los espacios que tenga alrededor
        var quote: Character? // comilla del valor, si tiene
        var value: String     // sin comillas
        var trailing: String  // lo que sigue al valor (comentario), tal cual

        var line: String {
            let quoted = quote.map { "\($0)\(value)\($0)" } ?? value
            return lead + key + equals + quoted + trailing
        }
    }

    private static func parse(_ line: String) -> Entry? {
        var rest = Substring(line)
        let lead1 = rest.prefix { $0 == " " || $0 == "\t" }
        rest = rest.dropFirst(lead1.count)
        var lead = String(lead1)
        if rest.hasPrefix("export ") {
            lead += "export "
            rest = rest.dropFirst("export ".count)
            let more = rest.prefix { $0 == " " }
            lead += more
            rest = rest.dropFirst(more.count)
        }
        let key = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
        guard !key.isEmpty else { return nil }
        rest = rest.dropFirst(key.count)
        let before = rest.prefix { $0 == " " || $0 == "\t" }
        rest = rest.dropFirst(before.count)
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst()
        let after = rest.prefix { $0 == " " || $0 == "\t" }
        rest = rest.dropFirst(after.count)
        let equals = String(before) + "=" + String(after)

        if let q = rest.first, q == "\"" || q == "'" {
            // Valor entre comillas: hasta la comilla de cierre que no esté escapada.
            var index = rest.index(after: rest.startIndex)
            var escaped = false
            while index < rest.endIndex {
                let c = rest[index]
                if c == q && !escaped { break }
                escaped = c == "\\" && !escaped
                index = rest.index(after: index)
            }
            guard index < rest.endIndex else {
                return Entry(lead: lead, key: String(key), equals: equals, quote: nil, value: String(rest), trailing: "")
            }
            let value = String(rest[rest.index(after: rest.startIndex)..<index])
            let trailing = String(rest[rest.index(after: index)...])
            return Entry(lead: lead, key: String(key), equals: equals, quote: q, value: value, trailing: trailing)
        }
        // Sin comillas: el comentario empieza en " #".
        if let hash = rest.range(of: " #") ?? rest.range(of: "\t#") {
            var value = rest[..<hash.lowerBound]
            var trailing = String(rest[hash.lowerBound...])
            let spaces = value.reversed().prefix { $0 == " " || $0 == "\t" }
            value = value.dropLast(spaces.count)
            trailing = String(spaces.reversed()) + trailing
            return Entry(lead: lead, key: String(key), equals: equals, quote: nil, value: String(value), trailing: trailing)
        }
        let value = rest.reversed().drop { $0 == " " || $0 == "\t" }.reversed()
        let trailing = String(rest.dropFirst(value.count))
        return Entry(lead: lead, key: String(key), equals: equals, quote: nil, value: String(value), trailing: trailing)
    }

    /// Recorre las líneas y deja que `transform` cambie las entradas `KEY=…`.
    private static func mapEntries(_ text: String, _ transform: (inout Entry) -> Void) -> String {
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            var line = lines[i]
            let carriage = line.hasSuffix("\r")
            if carriage { line.removeLast() }
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"), var entry = parse(line) else { continue }
            let original = entry.line
            transform(&entry)
            if entry.line != original { lines[i] = entry.line + (carriage ? "\r" : "") }
        }
        return lines.joined(separator: "\n")
    }

    /// Valor de una clave (sin comillas), o nil si no está.
    public static func value(_ key: String, in text: String) -> String? {
        var found: String?
        _ = mapEntries(text) { entry in if entry.key == key { found = entry.value } }
        return found
    }

    /// Cambia el valor de una clave conservando sus comillas y su comentario. Si no está, la agrega al final.
    public static func set(_ key: String, value: String, in text: String) -> String {
        var present = false
        let updated = mapEntries(text) { entry in
            guard entry.key == key else { return }
            present = true
            entry.value = value
            if entry.quote == nil && needsQuotes(value) { entry.quote = "\"" }
        }
        guard !present else { return updated }
        let line = "\(key)=" + (needsQuotes(value) ? "\"\(value)\"" : value)
        if text.isEmpty { return line + "\n" }
        return text.hasSuffix("\n") ? text + line + "\n" : text + "\n" + line + "\n"
    }

    /// Reemplaza un host por otro en las claves que lo repiten (SESSION_DOMAIN, SANCTUM_STATEFUL_DOMAINS),
    /// solo donde aparece como palabra entera ("app.test" no toca "miapp.test").
    public static func replaceHost(old: String, new: String, in text: String, keys: [String] = hostKeys) -> String {
        guard !old.isEmpty, old != new else { return text }
        let pattern = "(?<![A-Za-z0-9-])" + NSRegularExpression.escapedPattern(for: old) + "(?![A-Za-z0-9-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let template = NSRegularExpression.escapedTemplate(for: new)
        return mapEntries(text) { entry in
            guard keys.contains(entry.key) else { return }
            let range = NSRange(entry.value.startIndex..., in: entry.value)
            entry.value = regex.stringByReplacingMatches(in: entry.value, range: range, withTemplate: template)
        }
    }

    /// Host de una URL ("https://app.test:8000/x" → "app.test").
    public static func host(of url: String) -> String? {
        URLComponents(string: url)?.host.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// APP_URL nuevo y, si el host cambió, también los dominios que lo repetían.
    public static func rewriteAppURL(_ url: String, in text: String) -> String {
        let oldHost = value("APP_URL", in: text).flatMap(host(of:))
        var result = set("APP_URL", value: url, in: text)
        if let oldHost, let newHost = host(of: url) {
            result = replaceHost(old: oldHost, new: newHost, in: result)
        }
        return result
    }

    /// Una ruta SQLite relativa cambia de base al copiar .env. Conserva la conexión existente,
    /// igual que con MySQL/Postgres, sin copiar la base ni ejecutar consultas.
    public static func preserveSQLiteConnection(in text: String, root: String,
                                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        guard value("DB_CONNECTION", in: text)?.lowercased() == "sqlite",
              value("DB_URL", in: text)?.isEmpty != false else { return text }
        let database = value("DB_DATABASE", in: text) ?? "database/database.sqlite"
        guard !database.isEmpty, database != ":memory:", !database.hasPrefix("/"),
              !database.contains("$") else { return text }
        let absolute = (root as NSString).appendingPathComponent(database)
        guard exists(absolute) else { return text }
        return set("DB_DATABASE", value: absolute, in: text)
    }

    private static func needsQuotes(_ value: String) -> Bool {
        value.contains(" ") || value.contains("#") || value.contains("\t")
    }
}
