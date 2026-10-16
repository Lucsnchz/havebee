import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Terminal: continuidad del historial")
struct ConversationScrollbackTerminalTests {
    private func terminal() -> HiveTerminalView {
        _ = NSApplication.shared
        return HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 240))
    }

    private func entry(_ role: HistoryEntry.Role, _ text: String, agent: SessionKind = .claude) -> HistoryEntry {
        HistoryEntry(date: .reference, role: role, text: text, agent: agent)
    }

    @Test("El historial queda arriba del agente aunque limpie al iniciar, redibuje o haga /clear")
    func startupAndClear() {
        let view = terminal()
        view.restoreHistory([entry(.user, "Arreglá el stock"), entry(.assistant, "Validación lista"),
                             entry(.marker, "Cambio de IA: Claude Code → Codex")], agent: .codex)
        #expect(!view.visibleRowsText(0..<view.terminalDimensions.rows).joined().contains("Validación lista"))
        // En la práctica el proceso puede partir cada escape en distintos bloques de salida.
        for byte in Array("\u{1B}[2J\u{1B}[3J\u{1B}[HCodex listo".utf8) { view.receive([byte]) }
        #expect(view.fullText().contains("Validación lista") && view.fullText().contains("Codex listo"))
        view.receive(Array("\u{1B}c\u{1B}[3J\u{1B}[3JCodex redibujado".utf8)[...])
        #expect(view.fullText().contains("Validación lista") && view.fullText().contains("Codex redibujado"))
        view.sendInput([13])
        view.receive(Array("\u{1B}[2J\u{1B}[3J\u{1B}[HNueva conversación".utf8)[...])
        let text = view.fullText()
        #expect(text.contains("Validación lista") && text.contains("Codex redibujado") && text.contains("Nueva conversación"))
        // Se puede llegar al principio con el mismo scroll de la terminal.
        view.scrollTo(row: 0)
        #expect(view.visibleRowsText(0..<view.terminalDimensions.rows).joined().contains("Arreglá el stock"))
    }

    @Test("Restaurar texto no ejecuta escapes ni manda historial al proceso")
    func inertText() {
        let view = terminal()
        var input: [UInt8] = []
        view.onProcessInput = { input += $0 }
        view.restoreHistory([entry(.user, "Español 🐝 日本語\r\n\t\u{1B}[6n\u{1B}]0;título\u{7}\u{9B}3J\nÚltimo mensaje")], agent: .codex)
        #expect(input.isEmpty)
        #expect(view.fullText().contains("Español 🐝 日本語"))
        #expect(view.fullText().contains("Último mensaje"))
    }

    @Test("Una conversación de más de 10.000 líneas conserva también el principio")
    func largeHistory() {
        let view = terminal()
        view.restoreHistory([entry(.assistant, (1...10_100).map { "Mensaje \($0)" }.joined(separator: "\n"))], agent: .codex)
        view.receive(Array("\u{1B}[2J\u{1B}[3J\u{1B}[HAgente nuevo".utf8)[...])
        let text = view.fullText()
        #expect(text.contains("Mensaje 1\n") && text.contains("Mensaje 10100"))
        #expect(text.contains("Agente nuevo"))
    }

    @Test("Se ven mensajes separados y Markdown renderizado; los adjuntos no muestran etiquetas internas")
    func readableMessages() {
        let view = terminal()
        let user = "Revisá el diseño\n<image name=[Image #1] path=\"/tmp/imagen.png\">\n</image>\n[Image #1]"
        let response = "## Cambios\nListo: **separé los mensajes** y agregué [el archivo](/tmp/app.swift).\n\n- Una lista\n\n```swift\nlet name = \"**literal**\"\nlet view = \"<div>hola</div>\"\n```"
        view.restoreHistory([entry(.user, user), entry(.assistant, response),
                             entry(.marker, "Cambio de IA: Claude Code → Codex"),
                             entry(.assistant, "Continúo con la revisión", agent: .codex)], agent: .codex)
        let text = view.fullText()
        #expect(text.contains("╭─ Vos") && text.contains("● Claude Code") && text.contains("● Codex"))
        #expect(text.contains("│  Revisá el diseño") && text.contains("Imagen adjunta"))
        #expect(!text.contains("<image") && !text.contains("[Image #1]") && !text.contains("/tmp/imagen.png"))
        #expect(text.contains("Cambios") && !text.contains("## Cambios") && !text.contains("**separé"))
        #expect(text.contains("el archivo") && !text.contains("](/tmp/app.swift)"))
        #expect(text.contains("• Una lista") && text.contains("┌ swift") && !text.contains("```"))
        #expect(text.contains("\"**literal**\"") && text.contains("<div>hola</div>"))
    }
}
