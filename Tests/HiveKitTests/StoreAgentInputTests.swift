import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Un store con un repo y una sesión abierta (con procesos falsos), que no estás mirando.
@MainActor
private struct AgentSetup {
    let world = TestWorld()
    let repo = GitRepo()
    let store: AppStore
    let project: Project

    init() async throws {
        store = world.makeStore()
        await store.addProject(at: repo.path)
        project = try #require(store.repoProjects.first)
    }

    func open(_ kind: SessionKind) throws -> (Session, SessionRuntime) {
        store.requestNewSession(branchId: project.branches[0].id, kind: kind)
        let session = try #require(store.project(project.id)?.branches[0].sessions.last)
        store.activate(session.id)
        store.select(nil)
        return (session, try #require(store.runtimes[session.id]))
    }

    func permission(_ id: UUID, _ message: String) {
        store.handle([HiveEvent(sessionId: id, source: "claude", name: "Notification",
                                payload: ["notification_type": "permission_prompt", "message": .string(message)])])
    }

    func type(_ id: UUID, _ bytes: [UInt8]) {
        store.userInput(id, bytes[...])
    }
}

private let esc: UInt8 = 0x1B

@MainActor
@Suite("Store: lo que escribís en un agente")
struct StoreAgentInputTests {
    @Test("Esc después de un pedido de permiso la saca de «Necesita permiso», sin avisar")
    func escapeLeavesAttention() async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.claude)
        s.permission(session.id, "Permiso para Bash")
        #expect(rt.status == .attention)
        let posts = s.world.notifier.posts.count
        s.type(session.id, [esc])
        #expect(rt.status == .waiting)
        #expect(rt.workingSince == nil)
        #expect(!rt.unseen)
        #expect(s.world.notifier.posts.count == posts)
        #expect(s.world.badge == nil)
    }

    @Test("Esc mientras trabaja lo corta; en «Lista» no cambia nada")
    func escapeWhileWorking() async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.codex)
        s.type(session.id, [esc])
        #expect(rt.status == .idle)
        s.type(session.id, Array("hacé algo\r".utf8))
        #expect(rt.status == .working && rt.workingSince != nil)
        s.type(session.id, [esc])
        #expect(rt.status == .waiting && rt.workingSince == nil)
        #expect(s.world.notifier.posts.isEmpty)
        // Una flecha empieza con ESC pero no es un Esc solo.
        s.type(session.id, [esc, 0x5B, 0x41])
        #expect(rt.status == .waiting)
    }

    @Test("ESC CR, Shift+Enter (CSI-u) y un pegado no la ponen a trabajar", arguments: [
        [esc, 13],                                              // Option+Enter
        Array("\u{1B}[13;2u".utf8),                              // Shift+Enter en CSI-u
        Array("\u{1B}[13;5u".utf8),                              // Ctrl+Enter
        Array("\u{1B}[200~primera\rsegunda\u{1B}[201~".utf8),    // pegado con saltos de línea
        Array("hola".utf8),
    ])
    func notSubmit(bytes: [UInt8]) async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.claude)
        s.type(session.id, bytes)
        #expect(rt.status == .idle)
    }

    @Test("Con el protocolo de teclado de kitty: ESC[13u manda y ESC[27u es un Esc")
    func kittyKeys() async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.claude)
        s.type(session.id, Array("\u{1B}[13u".utf8))
        #expect(rt.status == .working)
        s.permission(session.id, "Permiso para Bash")
        #expect(rt.status == .attention)
        s.type(session.id, Array("\u{1B}[27u".utf8))
        #expect(rt.status == .waiting)
    }

    @Test("Un pegado que termina y después un Enter sí la pone a trabajar")
    func pasteThenEnter() async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.claude)
        s.type(session.id, Array("\u{1B}[200~arreglá esto\u{1B}[201~".utf8))
        #expect(rt.status == .idle)
        s.type(session.id, [13])
        #expect(rt.status == .working)
    }

    @Test("Un Enter, aunque venga con texto, sí la pone a trabajar")
    func submit() async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.claude)
        s.type(session.id, Array("listo\r".utf8))
        #expect(rt.status == .working)
    }

    @Test("En una Terminal, Esc y Enter no cambian el estado")
    func shellIgnoresKeys() async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.shell)
        s.type(session.id, [13])
        #expect(rt.status == .idle)
        s.type(session.id, [esc])
        #expect(rt.status == .idle)
    }

    @Test("El aviso de permiso se ve mientras dura y se limpia al salir de ese estado")
    func noticeLifecycle() async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.claude)
        #expect(rt.notice == nil)
        s.permission(session.id, "Permiso para Bash: npm test")
        #expect(rt.notice == "Permiso para Bash: npm test")
        #expect(s.world.notifier.posts.last?.subtitle.hasSuffix("· Necesita permiso") == true)
        // Otro pedido lo reemplaza. Llega como PermissionRequest: un Notification permission_prompt
        // mientras ya pide permiso es el aviso repetido de Claude (a los 6 s) y no cambia nada.
        s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "PermissionRequest",
                                  payload: ["tool_name": "Edit", "tool_input": ["file_path": "app.php"]])])
        #expect(rt.notice == "Pide permiso para editar app.php")
        s.permission(session.id, "Claude needs your permission to use Edit")
        #expect(rt.notice == "Pide permiso para editar app.php")
        s.type(session.id, [13]) // lo aprobaste
        #expect(rt.status == .working)
        #expect(rt.notice == nil)
        s.permission(session.id, "Permiso para Bash")
        s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "Listo."])])
        #expect(rt.status == .waiting && rt.notice == nil)
        #expect(s.world.notifier.posts.last?.subtitle.hasSuffix("· Tu turno") == true)
    }

    @Test("La primera sesión de Claude se renombra sola con el primer pedido, una sola vez")
    func autoName() async throws {
        let s = try await AgentSetup()
        let (session, _) = try s.open(.claude)
        func prompt(_ text: String) {
            s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": .string(text)])])
        }
        prompt("/clear")
        #expect(s.store.sessionContext(session.id)?.session.name == "Claude 1") // un comando no da nombre
        prompt("Agregá validación de stock al checkout")
        #expect(s.store.sessionContext(session.id)?.session.name == "Agregá validación de stock al")
        prompt("Ahora corré los tests")
        #expect(s.store.sessionContext(session.id)?.session.name == "Agregá validación de stock al")
        // Se guardó.
        #expect(s.world.makeStore().sessionContext(session.id)?.session.name == "Agregá validación de stock al")
    }

    @Test("Una sesión renombrada a mano no se toca, aunque se llame «Claude 3»")
    func manualNameIsKept() async throws {
        let s = try await AgentSetup()
        let (session, _) = try s.open(.claude)
        s.store.beginRename(.session(session.id))
        s.store.renameText = "Claude 3"
        s.store.commitRename(try #require(s.store.rename))
        #expect(s.store.sessionContext(session.id)?.session.autoNamed == false)
        s.store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Arreglá el login"])])
        #expect(s.store.sessionContext(session.id)?.session.name == "Claude 3")
    }

    @Test("Codex también toma el nombre de lo primero que le pediste")
    func autoNameCodex() async throws {
        let s = try await AgentSetup()
        let (session, _) = try s.open(.codex)
        s.store.handle([HiveEvent(sessionId: session.id, source: "codex", name: "notify",
                                  payload: ["type": "agent-turn-complete", "thread-id": "t-1", "input-messages": ["Subí la versión a 2.0"],
                                            "last-assistant-message": "Hecho"])])
        #expect(s.store.sessionContext(session.id)?.session.name == "Subí la versión a 2.0")
    }

    // MARK: - Transcripts

    @Test("Claude: el transcript_path queda anotado y su texto se copia al historial de Hive, sin repetir")
    func claudeTranscriptIsArchived() async throws {
        let s = try await AgentSetup()
        let (session, _) = try s.open(.claude)
        let transcript = s.world.agents.claudeConfigDir.appendingPathComponent("projects/-code-tienda/c-1.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgentTranscriptFixtures.claude.write(to: transcript, atomically: true, encoding: .utf8)
        let stop = HiveEvent(sessionId: session.id, source: "claude", name: "Stop",
                             payload: ["session_id": "c-1", "transcript_path": .string(transcript.path), "last_assistant_message": "Listo."])
        s.store.handle([stop])
        s.store.handle([stop])
        let segments = s.store.history.transcriptSegments(session.id)
        #expect(segments.map(\.conversationId) == ["c-1"])
        #expect(segments.first?.path == transcript.path)
        #expect(segments.first?.agent == .claude)
        #expect(await waitUntil { s.store.history.loadArchive(session.id).count == 2 })
        try await Task.sleep(nanoseconds: 300_000_000)
        let archived = s.store.history.loadArchive(session.id)
        #expect(archived.map(\.text) == ["Agregá validación de stock", "Listo: ya valida el stock."])
        #expect(archived.map(\.role) == [.user, .assistant])
    }

    @Test("Codex: al terminar el turno se busca su rollout y se copia igual")
    func codexRolloutIsArchived() async throws {
        let s = try await AgentSetup()
        let (session, _) = try s.open(.codex)
        let thread = "019a12e6-0000-7000-8000-000000000001"
        let rollout = try AgentTranscriptFixtures.writeCodexRollout(s.world.agents.codexHome, thread: thread)
        s.store.handle([HiveEvent(sessionId: session.id, source: "codex", name: "notify",
                                  payload: ["type": "agent-turn-complete", "thread-id": .string(thread),
                                            "input-messages": ["Arreglá el login"], "last-assistant-message": "Listo."])])
        #expect(await waitUntil { s.store.history.loadArchive(session.id).count == 2 })
        let segments = s.store.history.transcriptSegments(session.id)
        #expect(segments.map(\.conversationId) == [thread])
        #expect(segments.first.map { URL(fileURLWithPath: $0.path).standardizedFileURL } == rollout.standardizedFileURL)
        #expect(s.store.history.loadArchive(session.id).map(\.text) == ["Arreglá el login", "Listo, el login funciona."])
    }

    @Test("Los avisos de un subagente de Codex no cambian la sesión")
    func codexSubagentIsIgnored() async throws {
        let s = try await AgentSetup()
        let (session, rt) = try s.open(.codex)
        let main = "019a12e6-0000-7000-8000-000000000001"
        let sub = "019a12e6-0000-7000-8000-0000000000aa"
        try AgentTranscriptFixtures.writeCodexRollout(s.world.agents.codexHome, thread: main)
        try AgentTranscriptFixtures.writeCodexRollout(s.world.agents.codexHome, thread: sub, subagent: true)
        func turnComplete(_ thread: String, _ reply: String) {
            s.store.handle([HiveEvent(sessionId: session.id, source: "codex", name: "notify",
                                      payload: ["type": "agent-turn-complete", "thread-id": .string(thread),
                                                "input-messages": ["Revisá los tests"], "last-assistant-message": .string(reply)])])
        }
        turnComplete(main, "Listo.")
        #expect(s.store.sessionContext(session.id)?.session.agentSessionId == main)
        s.type(session.id, Array("seguí\r".utf8))
        #expect(rt.status == .working)
        let posts = s.world.notifier.posts.count
        turnComplete(sub, "Soy el subagente.")
        #expect(rt.status == .working)
        #expect(s.store.sessionContext(session.id)?.session.agentSessionId == main)
        #expect(s.store.sessionContext(session.id)?.session.lastMessage == "Listo.")
        #expect(s.world.notifier.posts.count == posts)
        #expect(!s.store.history.load(session.id).contains { $0.text == "Soy el subagente." })
    }
}

/// Transcripts mínimos con el formato de Claude Code 2.1.x y de Codex.
private enum AgentTranscriptFixtures {
    static let claude = #"""
    {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Agregá validación de stock"},"uuid":"u1","timestamp":"2026-09-21T14:00:00.000Z","sessionId":"c-1"}
    {"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Listo: ya valida el stock."}]},"uuid":"a1","timestamp":"2026-09-21T14:01:00.000Z","sessionId":"c-1"}
    """#

    /// Escribe sessions/2026/10/12/rollout-…-<thread>.jsonl. Un subagente lo dice en su session_meta.
    @discardableResult
    static func writeCodexRollout(_ codexHome: URL, thread: String, subagent: Bool = false) throws -> URL {
        let source = subagent ? #"{"subagent":{"thread_spawn":{"parent_thread_id":"x"}}}"# : #""cli""#
        let text = """
        {"timestamp":"2026-10-12T13:00:00.000Z","type":"session_meta","payload":{"id":"\(thread)","timestamp":"2026-10-12T13:00:00.000Z","cwd":"/code/tienda","source":\(source)}}
        {"timestamp":"2026-10-12T13:00:05.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Arreglá el login"}]}}
        {"timestamp":"2026-10-12T13:00:22.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Listo, el login funciona."}]}}
        """
        let url = codexHome.appendingPathComponent("sessions/2026/10/12/rollout-2026-10-12T13-00-00-\(thread).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
