import HiveCore
import Testing

@Suite("Codex: fallo de arranque y borrador no enviado")
struct CodexStartupFailureTests {
    static let error = "Error: account/read failed during TUI bootstrap: account/read failed: workspace routing discovery timed out (code -32603)"

    @Test("Recupera solamente el borrador devuelto por Codex, con saltos e indentación", arguments: [
        "Revisá las rutas 🐝\n\n    Conservá esta indentación\nY continuá lo pendiente.",
        "Me pasó esto:\nUnsent draft:\nTexto anterior\n\n¿Podés revisarlo?"
    ])
    func draft(_ draft: String) throws {
        let output = "› texto de la interfaz\r\nUnsent draft:\r\n\(draft)\r\n\r\n\(Self.error)\r\n"
        let failure = try #require(CodexStartupFailure.parse(output: output))
        #expect(failure.unsentDraft == draft)
    }

    @Test("Reconoce el timeout aunque no haya borrador", arguments: ["", "Unsent draft:\n\n"])
    func noDraft(prefix: String) throws {
        let failure = try #require(CodexStartupFailure.parse(output: prefix + Self.error))
        #expect(failure.unsentDraft == nil)
    }

    @Test("No toma un error anterior, una cita ni otro fallo como timeout de arranque", arguments: [
        "Unsent draft:\nmensaje\n\nError: another failure",
        "> " + error,
        error + "\nCodex listo",
        "Error: account/read failed during TUI bootstrap: unauthorized",
        "Revisá esto: " + error
    ])
    func unrelated(output: String) {
        #expect(CodexStartupFailure.parse(output: output) == nil)
    }

    @Test("El desmontaje del TUI y los colores no se copian al borrador")
    func escapes() throws {
        let output = "\u{1B}]0;Codex\u{7}\u{1B}[?25h\r\nUnsent draft:\r\nRevisá 🐝\r\n\r\n\u{1B}[31m\(Self.error)\u{1B}[0m\r\n\u{1B}[?1004l"
        let failure = try #require(CodexStartupFailure.parse(output: output))
        #expect(failure.unsentDraft == "Revisá 🐝")
    }
}
