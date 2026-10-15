import Foundation

/// Qué abrir cuando hacés ⌘clic en algo de la terminal: una URL, o un archivo (con su línea y
/// columna si las tiene, como en «app/Models/Order.php:42») o una carpeta.
public enum TerminalLink {
    public enum Target: Equatable, Sendable {
        case url(URL)
        case file(path: String, line: Int?, column: Int?)
        case folder(path: String)
    }

    public enum Kind: Sendable {
        case file
        case folder
    }

    /// Lo que hay en el disco en una ruta (nil si no existe).
    public static func diskKind(_ path: String) -> Kind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .folder : .file
    }

    /// Resuelve el texto de un enlace. Las rutas relativas, «./» y «~/» se resuelven contra `cwd`
    /// (la carpeta de la sesión o la que avisó el shell con OSC 7) y `home`. Devuelve nil si es
    /// una ruta que no existe.
    public static func resolve(_ text: String, cwd: String?, home: String,
                               kind: (String) -> Kind? = TerminalLink.diskKind) -> Target? {
        let link = trimmed(text)
        guard !link.isEmpty else { return nil }

        if let url = webURL(link) { return .url(url) }

        var pathText = link
        if link.lowercased().hasPrefix("file://") {
            guard let url = URL(string: link), url.isFileURL else { return nil }
            pathText = url.path
        }
        let (rawPath, line, column) = splitLocation(pathText)
        guard !rawPath.isEmpty else { return nil }

        var candidates = [rawPath]
        // Las rutas de un diff de git vienen con a/ y b/ adelante.
        if rawPath.hasPrefix("a/") || rawPath.hasPrefix("b/") { candidates.append(String(rawPath.dropFirst(2))) }
        for candidate in candidates {
            guard let path = absolute(candidate, cwd: cwd, home: home), let found = kind(path) else { continue }
            switch found {
            case .file: return .file(path: path, line: line, column: column)
            case .folder: return .folder(path: path)
            }
        }
        return nil
    }

    /// La palabra de `line` que está en la columna `column` (lo que se abriría con un clic).
    public static func candidate(in line: String, at column: Int) -> String? {
        let characters = Array(line)
        guard column >= 0, column < characters.count, !isBoundary(characters[column]) else { return nil }
        var start = column
        while start > 0, !isBoundary(characters[start - 1]) { start -= 1 }
        var end = column
        while end + 1 < characters.count, !isBoundary(characters[end + 1]) { end += 1 }
        let word = trimmed(String(characters[start...end]))
        return word.isEmpty ? nil : word
    }

    /// La carpeta que avisa el shell con OSC 7 (`file://equipo/ruta`, con %20 y demás).
    public static func directory(fromOSC7 value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return value }
        guard let url = URL(string: value), url.isFileURL, !url.path.isEmpty else { return nil }
        return url.path
    }

    // MARK: - Partes

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "\"'`<>|".contains(character)
    }

    /// Saca comillas, paréntesis y signos de puntuación que rodean al enlace en el texto.
    private static func trimmed(_ text: String) -> String {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading: Set<Character> = ["(", "[", "{", "<", "\"", "'", "`", "«"]
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ">", "\"", "'", "`", "»"]
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let first = link.first, leading.contains(first) { link.removeFirst() }
        while let last = link.last {
            if trailing.contains(last) {
                link.removeLast()
            } else if let open = pairs[last], link.filter({ $0 == last }).count > link.filter({ $0 == open }).count {
                // Un paréntesis de cierre que no abre nada es del texto de alrededor.
                link.removeLast()
            } else {
                break
            }
        }
        return link
    }

    private static func webURL(_ link: String) -> URL? {
        let lower = link.lowercased()
        if lower.hasPrefix("www.") { return URL(string: "https://" + link) }
        guard let colon = link.firstIndex(of: ":") else { return nil }
        let scheme = link[..<colon]
        guard let first = scheme.first, first.isLetter, scheme.count > 1,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
        let rest = link[link.index(after: colon)...]
        guard scheme.lowercased() != "file", rest.hasPrefix("//") || scheme.lowercased() == "mailto" else { return nil }
        if let url = URL(string: link) { return url }
        // Con espacios o caracteres sin codificar.
        let allowed = CharacterSet.urlQueryAllowed.union(.urlPathAllowed).union(CharacterSet(charactersIn: "#"))
        return link.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    /// «ruta:12:3», «ruta:12» y «ruta(12,3)» → ruta, línea y columna.
    private static func splitLocation(_ text: String) -> (String, Int?, Int?) {
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
            let numbers = inner.split(separator: ",", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if (1...2).contains(numbers.count), numbers.allSatisfy({ $0 != nil }) {
                return (String(text[..<open]), numbers[0], numbers.count > 1 ? numbers[1] : nil)
            }
        }
        var path = Substring(text)
        var numbers: [Int] = []
        while numbers.count < 2, let colon = path.lastIndex(of: ":"), let number = Int(path[path.index(after: colon)...]) {
            numbers.insert(number, at: 0)
            path = path[..<colon]
        }
        return (String(path), numbers.first, numbers.count > 1 ? numbers[1] : nil)
    }

    private static func absolute(_ path: String, cwd: String?, home: String) -> String? {
        let full: String
        if path == "~" {
            full = home
        } else if path.hasPrefix("~/") {
            full = (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if path.hasPrefix("/") {
            full = path
        } else if let cwd, !cwd.isEmpty {
            full = (cwd as NSString).appendingPathComponent(path)
        } else {
            return nil
        }
        return URL(fileURLWithPath: full).standardized.path
    }
}
