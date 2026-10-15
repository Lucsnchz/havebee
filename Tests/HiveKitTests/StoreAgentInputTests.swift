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
        s.permission(session.id, "Permiso para editar app.php") // otro pedido lo reemplaza
        #expect(rt.notice == "Permiso para editar app.php")
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
}
