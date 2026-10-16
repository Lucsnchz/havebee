import Foundation

/// La parte de la conversación de Hive que el proceso nuevo no puede volver a dibujar.
public enum ConversationScrollback {
    public static func text(_ entries: [HistoryEntry], agent: SessionKind, resuming: Bool) -> String {
        HistoryExport.plainText(previousEntries(entries, resuming: resuming), agent: agent.label)
    }

    /// Conserva los roles y el Markdown para que la vista pueda darles formato al dibujar.
    public static func previousEntries(_ entries: [HistoryEntry], resuming: Bool) -> [HistoryEntry] {
        if resuming {
            // El agente vuelve a dibujar su conversación nativa. Hive recupera lo anterior al
            // último cambio de IA o /clear para no duplicar los mensajes de la conversación actual.
            guard let boundary = entries.lastIndex(where: {
                $0.role == .marker && ($0.text.hasPrefix(AgentHandoff.markerPrefix)
                    || $0.text == "/clear" || $0.text == "Nueva conversación")
            }) else { return [] }
            return Array(entries[...boundary])
        }
        return entries
    }

    /// El historial es texto, nunca salida ejecutable de terminal (OSC, borrados, consultas, etc.).
    public static func displayText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        return String(normalized.unicodeScalars.filter {
            $0.value == 10 || ($0.value >= 32 && !(127...159).contains($0.value))
        })
    }
}
