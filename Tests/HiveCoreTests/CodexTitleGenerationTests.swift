import Foundation
import Testing
@testable import HiveCore

@Suite("Codex: titulación interna y avisos reales")
struct CodexTitleGenerationTests {
    private let prompt = """
    Generate a concise, single-line task title of at most 36 characters and under five words where possible. Start with an imperative verb. Capitalize only the first word unless the user's language, proper nouns, acronyms, or code terms require otherwise. Preserve ticket references exactly. Write in the user's language. Do not use quotes, markdown, or trailing punctuation. Do not answer the request.

    User prompt:
    podes revisar el historial? que quedo pendiente lo de mercado pago qr
    """
    private let title = #"{"title":"Revisar QR de Mercado Pago"}"#

    private func event(inputs: [String], reply: String) -> HiveEvent {
        HiveEvent(sessionId: UUID(), source: "codex", name: "notify", payload: [
            "type": "agent-turn-complete", "thread-id": "title-thread",
            "input-messages": .array(inputs.map(JSONValue.string)), "last-assistant-message": .string(reply),
        ])
    }

    @Test("El título auxiliar no cambia el turno ni la conversación", arguments: [SessionStatus.working, .waiting, .attention],
          [nil, "main-thread", "title-thread"] as [String?])
    func ignoreTitle(status: SessionStatus, agentId: String?) {
        let result = AgentEventInterpreter.interpret(event(inputs: [prompt], reply: title), status: status, agentSessionId: agentId)
        #expect(result == AgentEventOutcome())
    }

    @Test("Reconoce el pedido interno con contexto inyectado y aunque cambie el formato de su respuesta")
    func injectedContext() {
        let inputs = ["\n" + prompt + "\n", "<environment_context>directorio de trabajo</environment_context>"]
        let result = AgentEventInterpreter.interpret(event(inputs: inputs, reply: "Revisar QR de Mercado Pago"),
                                                     status: .working, agentSessionId: "main-thread")
        #expect(result == AgentEventOutcome())
    }

    @Test("Un JSON de la respuesta real sigue siendo una respuesta, aunque haya un título anterior")
    func realJSON() {
        for inputs in [["Devolvé un ejemplo de JSON con title"], [prompt, "Devolvé un ejemplo de JSON con title"], []] {
            let result = AgentEventInterpreter.interpret(event(inputs: inputs, reply: title), status: .working, agentSessionId: "title-thread")
            #expect(result.status == .waiting)
            #expect(result.notification == title && result.reply == title)
            #expect(result.history.last?.text == title)
        }
    }
}
