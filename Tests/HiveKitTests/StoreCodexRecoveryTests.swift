import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: identidad persistida de Codex")
struct StoreCodexRecoveryTests {
    private func rollout(_ id: String, in world: TestWorld) throws -> URL {
        let meta: JSONValue = ["type": "session_meta", "payload": [
            "id": .string(id), "cwd": .string(world.home.path), "source": "cli"
        ]]
        return world.dir.write("codex/sessions/2026/10/16/rollout-\(id).jsonl",
                               String(decoding: try JSONSerialization.data(withJSONObject: meta.anyValue), as: UTF8.self) + "\n")
    }

    @Test("Reabrir recupera y guarda el ID original; sin nativo descarta el ID roto", arguments: [true, false])
    func reopen(nativeExists: Bool) throws {
        let world = TestWorld()
        let store = world.makeStore()
        let branch = try #require(store.scratchProject?.branches.first)
        store.requestNewSession(branchId: branch.id, kind: .codex)
        let id = try #require(store.scratchProject?.allSessions.last?.id)
        store.projects.updateSession(id) {
            $0.agentSessionId = "temporary-summary"
            $0.lastLaunchedAt = world.now
        }
        store.history.append(HistoryEntry(date: world.now, role: .assistant, text: "Permisos comprobados", agent: .codex),
                             sessionId: id, agentName: "Codex")
        if nativeExists {
            let url = try rollout("original", in: world)
            store.history.recordTranscript(sessionId: id, agent: .codex, conversationId: "original", path: url.path, now: world.now)
        }
        // Otra conversación del mismo directorio no puede ocupar este chat.
        _ = try rollout("neighbor", in: world)
        store.saveNow()

        let reopened = world.makeStore()
        reopened.activate(id)
        let expected = nativeExists ? "original" : nil
        #expect(reopened.sessionContext(id)?.session.agentSessionId == expected)
        let args = try #require(world.processes.launches.last?.args)
        #expect(!args.contains("temporary-summary") && !args.contains("neighbor"))
        #expect(args.contains("resume") == nativeExists)
        #expect(!args.contains(InterruptedWork.prompt))
        if !nativeExists {
            #expect(args.contains { $0.contains("developer_instructions=") && $0.contains("Permisos comprobados") })
        }
        #expect(world.makeStore().sessionContext(id)?.session.agentSessionId == expected)
    }

    @Test("Un thread temporal desconocido no reemplaza el nativo; /new guardado sí")
    func incomingIdentity() throws {
        let world = TestWorld()
        let store = world.makeStore()
        let branch = try #require(store.scratchProject?.branches.first)
        store.requestNewSession(branchId: branch.id, kind: .codex)
        let id = try #require(store.scratchProject?.allSessions.last?.id)
        _ = try rollout("original", in: world)
        store.projects.updateSession(id) { $0.agentSessionId = "original" }
        store.activate(id)
        store.select(nil)
        let rt = try #require(store.runtimes[id])
        store.setStatus(rt, .working)
        let before = try #require(store.sessionContext(id)?.session)
        func complete(_ thread: String) {
            store.handle([HiveEvent(sessionId: id, source: "codex", name: "notify", payload: [
                "type": "agent-turn-complete", "thread-id": .string(thread),
                "input-messages": ["Un pedido"], "last-assistant-message": "Listo"
            ], launchId: rt.launchId)])
        }
        complete("unknown-temporary")
        #expect(store.sessionContext(id)?.session == before)
        #expect(rt.status == .working && !rt.hooksSeen)
        #expect(world.notifier.posts.isEmpty && store.history.load(id).isEmpty)

        _ = try rollout("new-conversation", in: world)
        complete("new-conversation")
        #expect(store.sessionContext(id)?.session.agentSessionId == "new-conversation")
        #expect(rt.status == .waiting && world.notifier.posts.count == 1)
        #expect(store.history.load(id).map(\.text) == ["Nueva conversación", "Un pedido", "Listo"])
    }
}
