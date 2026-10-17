import Foundation

/// Títulos y resúmenes de Codex corren en threads temporales que heredan el notify del chat.
/// No son respuestas al usuario, trabajo pendiente ni conversaciones que se puedan reanudar.
public enum CodexInternalTurn {
    static func isRequest(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = text.hasPrefix("Generate a concise, single-line task title of at most ")
            && text.contains("Do not answer the request.") && text.contains("User prompt:")
        let catchUp = text.hasPrefix("Write a brief catch-up for a user returning to this task.")
            && text.contains("Return JSON with summary and nullable next_action.")
            && text.contains("Next_action:") && text.contains("\nConversation:")
        return title || catchUp
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

    /// Repara la lectura de registros viejos sin ocultar JSON solicitado por el usuario. El hook
    /// guardó el pedido interno, su respuesta y la falsa divisoria juntos, con la misma fecha.
    public static func removingFromHistory(_ entries: [HistoryEntry], defaultAgent: SessionKind? = nil) -> [HistoryEntry] {
        var removed = Set<Int>()
        for index in entries.indices {
            let entry = entries[index]
            guard (entry.agent ?? defaultAgent) == .codex, entry.role == .user, isRequest(entry.text) else { continue }
            removed.insert(index)
            func sameEvent(_ other: HistoryEntry) -> Bool {
                (other.agent ?? defaultAgent) == .codex && abs(other.date.timeIntervalSince(entry.date)) < 2
            }
            if index > 0, entries[index - 1].role == .marker, entries[index - 1].text == "Nueva conversación",
               sameEvent(entries[index - 1]) { removed.insert(index - 1) }
            if index + 1 < entries.count, entries[index + 1].role == .assistant,
               sameEvent(entries[index + 1]) { removed.insert(index + 1) }
        }
        return entries.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }
}
