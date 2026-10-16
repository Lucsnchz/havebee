import Foundation
import Testing
@testable import HiveCore

@Suite("Formato del chat recuperado")
struct ConversationTerminalRendererTests {
    private func entry(_ role: HistoryEntry.Role, _ text: String) -> HistoryEntry {
        HistoryEntry(date: .reference, role: role, text: text, agent: .claude)
    }

    @Test("El formato conserva el contenido original y solo genera escapes de estilo o de enlace")
    func formatting() {
        let entries = [entry(.user, "Un pedido"), entry(.assistant, "## Resumen\n**Listo**, con `código` y *cursiva*.\n[Archivo](/tmp/code.swift:12)")]
        let result = ConversationTerminalRenderer.render(entries, agent: .codex, columns: 80)
        #expect(result.ansi.contains("\u{1B}[1m") && result.ansi.contains("\u{1B}[3m") && result.ansi.contains("\u{1B}[36m"))
        #expect(result.ansi.contains("\u{1B}]8;;/tmp/code.swift:12\u{1B}\\"))
        #expect(!result.ansi.contains("## Resumen") && !result.ansi.contains("**Listo**"))
        #expect(entries[1].text.contains("**Listo**") && entries[1].text.contains("[Archivo]"))
        #expect(result.lineCount == result.ansi.components(separatedBy: "\n").count)
    }

    @Test("No confunde código, listas o nombres con Markdown; envuelve mensajes largos", arguments: [36, 80, 140])
    func widths(_ columns: Int) {
        let result = ConversationTerminalRenderer.render([entry(.assistant,
            "Texto largo " + String(repeating: "acción ", count: 100) + "\n- [x] Listo\n- [ ] Pendiente\n```html\n<div class=\"a_b\">**literal**</div>\n```")], agent: .claude, columns: columns)
        #expect(!result.ansi.contains("- [x]") && !result.ansi.contains("- [ ]") && !result.ansi.contains("```"))
        #expect(result.ansi.contains("☑") && result.ansi.contains("☐") && result.ansi.contains("**literal**"))
        #expect(result.lineCount > 15)
    }

    @Test("Los mensajes auxiliares de titulación no se dibujan como pedidos del usuario")
    func titleMessages() {
        let entries = [entry(.user, "Mi pedido real"),
                       entry(.user, "Generate a concise, single-line task title of at most 36 characters. Do not answer the request.\n\nUser prompt:\nMi pedido real"),
                       entry(.assistant, #"{"title":"Arreglar el chat"}"#), entry(.assistant, "Voy a revisarlo")]
        let result = ConversationTerminalRenderer.render(entries, agent: .claude, columns: 80)
        #expect(result.ansi.contains("Mi pedido real") && result.ansi.contains("Voy a revisarlo"))
        #expect(!result.ansi.contains("Generate a concise") && !result.ansi.contains("{\"title\""))
        // Un JSON que forma parte de la conversación sí se muestra.
        let json = ConversationTerminalRenderer.render([entry(.assistant, #"{"title":"Un ejemplo"}"#)], agent: .claude, columns: 80)
        #expect(json.ansi.contains("Un ejemplo"))
    }
}
