import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: avisos de Codex sin tareas internas")
struct StoreCodexNotificationTests {
    @Test("Los títulos y resúmenes no pisan la sesión; la respuesta real avisa una sola vez", arguments: [nil, "real-thread"] as [String?], [false, true])
    func internalThenReply(agentId: String?, catchUp: Bool) async throws {
        let s = try await AppStoreSessionTests.Setup()
        let session = try s.newSession(.codex)
        s.store.activate(session.id)
        s.store.select(nil)
        s.store.projects.updateSession(session.id) {
            $0.agentSessionId = agentId
            $0.lastMessage = "Respuesta anterior"
        }
        let rt = try #require(s.store.runtimes[session.id])
        s.store.setStatus(rt, .working)
        let before = try #require(s.store.sessionContext(session.id)?.session)
        let lastEvent = rt.lastEventAt
        let prompt = catchUp
            ? "Write a brief catch-up for a user returning to this task. Return JSON with summary and nullable next_action.\nSummary: broad goal\nNext_action: unanswered question\nConversation:\nUser: Revisá el QR"
            : "Generate a concise, single-line task title of at most 36 characters. Do not answer the request.\n\nUser prompt:\nRevisá el QR"
        let titleEvent = HiveEvent(sessionId: session.id, source: "codex", name: "notify", payload: [
            "type": "agent-turn-complete", "thread-id": "title-thread", "input-messages": [.string(prompt)],
            "last-assistant-message": .string(catchUp ? #"{"summary":"QR revisado","next_action":null}"# : #"{"title":"Revisar QR de Mercado Pago"}"#),
        ])
        s.world.advance(1)
        s.store.handle([titleEvent])
        #expect(rt.status == .working && !rt.unseen)
        #expect(!rt.hooksSeen && rt.lastEventAt == lastEvent)
        #expect(s.world.notifier.posts.isEmpty && s.world.badge == nil)
        #expect(s.store.sessionContext(session.id)?.session == before)
        #expect(s.store.history.load(session.id).isEmpty)
        #expect(s.store.history.transcriptSegments(session.id).isEmpty)

        let answer = "Revisé el historial: falta validar el QR de Mercado Pago."
        s.store.handle([HiveEvent(sessionId: session.id, source: "codex", name: "notify", payload: [
            "type": "agent-turn-complete", "thread-id": "real-thread", "input-messages": ["Revisá el QR"],
            "last-assistant-message": .string(answer),
        ])])
        #expect(rt.status == .waiting && rt.unseen && rt.hooksSeen)
        #expect(s.world.notifier.posts.count == 1)
        let post = try #require(s.world.notifier.posts.last)
        #expect(post.body == answer && post.subtitle == "Revisá el QR · Tu turno")
        #expect(s.store.sessionContext(session.id)?.session.agentSessionId == "real-thread")
        #expect(s.store.sessionContext(session.id)?.session.lastMessage == answer)
        #expect(s.store.history.load(session.id).map(\.text) == ["Revisá el QR", answer])

        // Un título tardío tampoco reemplaza el aviso ni la respuesta ya recibida.
        s.store.handle([titleEvent])
        #expect(s.world.notifier.posts.count == 1)
        #expect(s.store.sessionContext(session.id)?.session.lastMessage == answer)
        #expect(s.store.sessionContext(session.id)?.session.agentSessionId == "real-thread")
    }
}
