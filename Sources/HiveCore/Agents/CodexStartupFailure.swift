import Foundation

/// Un fallo de arranque que Codex imprime después de cerrar su interfaz, antes de enviar el turno.
/// Solo recibe la salida de ese proceso, nunca el historial que Hive dibuja antes de lanzarlo.
public struct CodexStartupFailure: Equatable, Sendable {
    public let unsentDraft: String?

    public static func parse(output: String) -> Self? {
        // Al desmontar el TUI puede haber secuencias de color, cursor y título alrededor del aviso.
        // Se procesa al salir, no byte a byte: los escapes y caracteres UTF-8 pueden venir partidos.
        let text = output
            .replacingOccurrences(of: #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Solo el diagnóstico final. Una mención del error dentro de la conversación no alcanza.
        guard let error = text.split(separator: "\n", omittingEmptySubsequences: false).last,
              error.hasPrefix("Error: account/read failed during TUI bootstrap:"),
              error.contains("workspace routing discovery timed out") else { return nil }

        let beforeError = "\n" + text.dropLast(error.count)
        let marker = "\nUnsent draft:\n"
        // El reporte se imprime una vez al salir. El propio borrador puede citar «Unsent draft:».
        let draft = beforeError.range(of: marker).map {
            String(beforeError[$0.upperBound...]).trimmingCharacters(in: .newlines)
        }
        return Self(unsentDraft: draft.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
    }
}
