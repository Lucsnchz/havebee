import Foundation

/// Codex puede generar el título en otro thread que hereda el notify de la conversación.
/// Ese turno auxiliar no es una respuesta al usuario ni una nueva conversación de Hive.
public enum CodexTitleGeneration {
    static func isRequest(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("Generate a concise, single-line task title of at most ")
            && text.contains("Do not answer the request.") && text.contains("User prompt:")
    }

    public static func isCompletion(_ event: HiveEvent) -> Bool {
        guard event.source == "codex", event.payload["type"]?.string == "agent-turn-complete" else { return false }
        // Importa el último pedido efectivo, no uno viejo ni el formato de la respuesta:
        // un usuario puede pedir un JSON con una clave "title" como parte de su trabajo.
        let inputs = event.payload["input-messages"]?.stringArray ?? []
        let prompt = inputs.last {
            let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && !TranscriptReader.isCodexInjected(text)
        }
        return prompt.map(isRequest) ?? false
    }
}
