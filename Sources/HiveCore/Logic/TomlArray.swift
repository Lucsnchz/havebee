import Foundation

/// Lector chico de TOML, solo para lo que Hive necesita del config.toml de Codex: el array de textos
/// de una clave de nivel superior (`notify`). Entiende textos básicos ("…") y literales ('…'), también
/// los de varias líneas, arrays en varias líneas, coma final y comentarios con #.
extension TOML {
    public enum StringArrayLookup: Equatable, Sendable {
        /// La clave no está (antes de la primera [tabla]).
        case missing
        case found([String])
        /// La clave está pero no pudimos leerla como un array de textos.
        case unreadable
    }

    public static func topLevelStringArray(_ key: String, in text: String) -> StringArrayLookup {
        var scanner = TOMLArrayScanner(text)
        return scanner.lookup(key)
    }
}

/// Recorre el texto por unidades Unicode. Cada función deja el cursor después de lo que leyó
/// y devuelve nil si el TOML no tiene la forma esperada.
private struct TOMLArrayScanner {
    let chars: [Unicode.Scalar]
    var i = 0

    init(_ text: String) {
        chars = Array(text.unicodeScalars)
    }

    var current: Unicode.Scalar? { i < chars.count ? chars[i] : nil }

    func peek(_ offset: Int) -> Unicode.Scalar? {
        i + offset < chars.count ? chars[i + offset] : nil
    }

    mutating func lookup(_ target: String) -> TOML.StringArrayLookup {
        while true {
            skipBlank(newlines: true)
            guard let c = current else { return .missing }
            // Empieza una tabla: lo que sigue ya no es de nivel superior.
            if c == "[" { return .missing }
            guard let key = readKey() else { return .missing }
            skipBlank(newlines: false)
            guard current == "=" else { return .missing }
            i += 1
            skipBlank(newlines: false)
            if key == target {
                guard let values = readStringArray() else { return .unreadable }
                return .found(values)
            }
            guard skipValue() else { return .missing }
        }
    }

    /// Espacios, tabs y comentarios; con `newlines`, también saltos de línea.
    mutating func skipBlank(newlines: Bool) {
        while let c = current {
            if c == " " || c == "\t" || (newlines && (c == "\n" || c == "\r")) {
                i += 1
            } else if c == "#" {
                while let d = current, d != "\n" { i += 1 }
            } else {
                return
            }
        }
    }

    /// Una clave (simple, entre comillas o con puntos). Devuelve el texto sin comillas si es una sola parte.
    mutating func readKey() -> String? {
        var parts: [String] = []
        while true {
            skipBlank(newlines: false)
            guard let c = current else { return nil }
            if c == "\"" || c == "'" {
                guard let quoted = readString(), !quoted.multiline else { return nil }
                parts.append(quoted.value)
            } else {
                var bare = ""
                while let d = current, d.properties.isAlphabetic || ("0"..."9").contains(d) || d == "_" || d == "-" {
                    bare.unicodeScalars.append(d)
                    i += 1
                }
                guard !bare.isEmpty else { return nil }
                parts.append(bare)
            }
            skipBlank(newlines: false)
            guard current == "." else { break }
            i += 1
        }
        return parts.joined(separator: ".")
    }

    mutating func readStringArray() -> [String]? {
        guard current == "[" else { return nil }
        i += 1
        var values: [String] = []
        while true {
            skipBlank(newlines: true)
            guard let c = current else { return nil }
            if c == "]" {
                i += 1
                return values
            }
            guard c == "\"" || c == "'", let string = readString() else { return nil }
            values.append(string.value)
            skipBlank(newlines: true)
            if current == "," {
                i += 1
            } else if current != "]" {
                return nil
            }
        }
    }

    /// Un texto básico o literal, de una o de varias líneas.
    mutating func readString() -> (value: String, multiline: Bool)? {
        guard let quote = current else { return nil }
        let literal = quote == "'"
        let multiline = peek(1) == quote && peek(2) == quote
        i += multiline ? 3 : 1
        // En los de varias líneas, el salto justo después de las comillas no cuenta.
        if multiline {
            if current == "\r" { i += 1 }
            if current == "\n" { i += 1 }
        }
        var value = String.UnicodeScalarView()
        while let c = current {
            if c == quote && (!multiline || (peek(1) == quote && peek(2) == quote)) {
                i += multiline ? 3 : 1
                // Hasta dos comillas más pegadas al cierre son parte del texto ("""a""""" = a"").
                var extra = 0
                while multiline, extra < 2, current == quote {
                    value.append(quote)
                    i += 1
                    extra += 1
                }
                return (String(value), multiline)
            }
            if !multiline && (c == "\n" || c == "\r") { return nil }
            if c == "\\" && !literal {
                i += 1
                guard let escaped = readEscape(multiline: multiline) else { return nil }
                value.append(contentsOf: escaped.unicodeScalars)
                continue
            }
            value.append(c)
            i += 1
        }
        return nil
    }

    mutating func readEscape(multiline: Bool) -> String? {
        guard let c = current else { return nil }
        i += 1
        switch c {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u", "U":
            let length = c == "u" ? 4 : 8
            guard i + length <= chars.count else { return nil }
            let hex = String(String.UnicodeScalarView(chars[i..<(i + length)]))
            guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
            i += length
            return String(Character(scalar))
        case " ", "\t", "\n", "\r":
            // Barra al final de la línea (solo en los de varias líneas): se come el salto y los espacios que siguen.
            guard multiline else { return nil }
            i -= 1
            while let d = current, d == " " || d == "\t" || d == "\n" || d == "\r" { i += 1 }
            return ""
        default:
            return nil
        }
    }

    /// Saltea un valor cualquiera (texto, número, array, tabla en línea) para seguir buscando.
    mutating func skipValue() -> Bool {
        guard let c = current else { return false }
        switch c {
        case "\"", "'":
            return readString() != nil
        case "[", "{":
            let close: Unicode.Scalar = c == "[" ? "]" : "}"
            i += 1
            while true {
                skipBlank(newlines: true)
                guard let d = current else { return false }
                if d == close {
                    i += 1
                    return true
                }
                // Un cierre que no corresponde (`[1}`): el TOML está roto y no hay cómo seguir.
                if d == "]" || d == "}" { return false }
                if d == "," || d == "=" {
                    i += 1
                } else if d == "\"" || d == "'" || d == "[" || d == "{" {
                    guard skipValue() else { return false }
                } else {
                    // Número, booleano, fecha o clave de una tabla en línea.
                    while let e = current, !" \t\r\n,=]}#".unicodeScalars.contains(e) { i += 1 }
                }
            }
        default:
            while let d = current, d != "\n", d != "#" { i += 1 }
            return true
        }
    }
}
