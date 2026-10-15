import Foundation

/// Nombre automático de una sesión a partir de lo primero que le pediste al agente
/// («Agregá validación de stock al checkout» → «Agregá validación de stock al»).
public enum SessionTitle {
    public static let maxLength = 32

    /// La primera línea con texto, sin @rutas ni /comandos, cortada en una palabra hasta
    /// `maxLength` caracteres y sin puntuación al final. nil si no queda nada.
    public static func from(prompt: String) -> String? {
        for line in prompt.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
                .filter { !$0.hasPrefix("@") && !$0.hasPrefix("/") }
            guard !words.isEmpty else { continue }
            var title = ""
            for word in words {
                let candidate = title.isEmpty ? String(word) : "\(title) \(word)"
                if candidate.count > maxLength {
                    // Una sola palabra larguísima: se corta igual.
                    if title.isEmpty { title = String(word.prefix(maxLength)) }
                    break
                }
                title = candidate
            }
            title = trimmingPunctuation(title)
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
}
