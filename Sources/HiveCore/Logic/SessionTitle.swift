import Foundation

/// Nombre automático de una sesión a partir de lo primero que le pediste al agente
/// («Agregá validación de stock al checkout» → «Agregá validación de stock»).
public enum SessionTitle {
    public static let maxLength = 32

    /// La primera línea con texto, sin @rutas ni /comandos, cortada en una palabra hasta
    /// `maxLength` caracteres y sin puntuación al final. Si se cortó algo, tampoco deja colgada una
    /// preposición, un artículo o una conjunción («…de stock al»). nil si no queda nada.
    public static func from(prompt: String) -> String? {
        for line in prompt.split(whereSeparator: \.isNewline) {
            let all = line.split(whereSeparator: \.isWhitespace)
            let words = all.filter { !isReference($0) }
            guard !words.isEmpty else { continue }
            var title = ""
            var used = 0
            for word in words {
                let candidate = title.isEmpty ? String(word) : "\(title) \(word)"
                if candidate.count > maxLength {
                    // Una sola palabra larguísima: se corta igual.
                    if title.isEmpty { title = String(word.prefix(maxLength)) }
                    break
                }
                title = candidate
                used += 1
            }
            // Quedó algo afuera: palabras que no entraron o una @ruta o un /comando al final de la línea.
            let cut = used < words.count || all.last.map(isReference) == true
            title = trimmingPunctuation(title)
            if cut { title = trimmingDanglingWords(title) }
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// Si la sesión todavía tiene su nombre automático («Claude 3») y no la renombraste vos.
    public static func canRename(_ session: Session) -> Bool {
        guard session.autoNamed != false else { return false }
        let prefix = session.kind.defaultName + " "
        guard session.name.hasPrefix(prefix) else { return false }
        let number = session.name.dropFirst(prefix.count)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    private static func isReference(_ word: Substring) -> Bool {
        word.hasPrefix("@") || word.hasPrefix("/")
    }

    private static let trailing = Set(".,;:!?…-–—¿¡")

    private static func trimmingPunctuation(_ text: String) -> String {
        var result = text
        while let last = result.last, trailing.contains(last) || last.isWhitespace { result.removeLast() }
        // Si el corte se llevó el cierre, sacamos también la apertura («Por qué falla» y no «¿Por qué falla» sin cierre).
        for (open, close) in [("¿", "?"), ("¡", "!")] where result.hasPrefix(open) && !result.contains(close) {
            result.removeFirst()
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Saca del final las palabras que no se sostienen solas («Agregá validación de stock al» →
    /// «Agregá validación de stock»). Si el título es todo eso («de la»), lo deja como estaba.
    static func trimmingDanglingWords(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        while let last = words.last, danglingWords.contains(last.lowercased()) {
            words.removeLast()
            // Lo que queda puede terminar en una coma («validación de stock, y» → «validación de stock»).
            if let previous = words.popLast() {
                let trimmed = trimmingPunctuation(previous)
                if !trimmed.isEmpty { words.append(trimmed) }
            }
        }
        guard !words.isEmpty else { return text }
        return trimmingPunctuation(words.joined(separator: " "))
    }

    /// Preposiciones, artículos, conjunciones y posesivos que no pueden cerrar un título, en español
    /// y en inglés. Se comparan en minúsculas.
    static let danglingWords: Set<String> = [
        // Preposiciones.
        "a", "al", "ante", "bajo", "con", "contra", "de", "del", "desde", "durante", "en", "entre", "hacia",
        "hasta", "mediante", "para", "por", "según", "sin", "sobre", "tras", "vía",
        // Artículos y posesivos.
        "el", "la", "lo", "los", "las", "un", "una", "unos", "unas", "mi", "mis", "tu", "tus", "su", "sus",
        // Conjunciones.
        "y", "e", "o", "u", "ni", "que", "pero", "si", "porque", "aunque", "como", "cuando", "donde", "mientras",
        // Inglés.
        "the", "an", "of", "to", "in", "on", "at", "for", "from", "with", "by", "about", "into", "onto", "over",
        "under", "as", "than", "via", "per", "and", "or", "but", "nor", "if", "because", "while", "when", "where",
        "whether", "that", "my", "your", "our", "their", "its",
    ]
}
