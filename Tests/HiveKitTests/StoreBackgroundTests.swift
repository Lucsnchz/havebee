import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Claude terminó su turno pero dejó subagentes o un workflow trabajando: la sesión tiene que seguir
/// figurando «Trabajando» (sin aviso ni globito) hasta que Claude retome y termine de verdad.
@MainActor
@Suite("Store: sesiones con trabajo en segundo plano")
struct StoreBackgroundTests {
    typealias Setup = AppStoreSessionTests.Setup

    func event(_ id: UUID, _ name: String, _ payload: JSONValue = [:]) -> HiveEvent {
        HiveEvent(sessionId: id, source: "claude", name: name, payload: payload)
    }

    let workflow: JSONValue = ["background_tasks": [["id": "w1", "type": "workflow", "status": "running", "name": "asistente"]],
                               "last_assistant_message": "Lancé el workflow; te aviso cuando termine."]

    /// Una sesión de Claude corriendo que no estás mirando, a mitad de un turno.
    func working(_ s: Setup) throws -> (Session, SessionRuntime) {
        let session = try s.newSession(.claude)
        s.store.activate(session.id)
        s.store.select(nil)
        let rt = try #require(s.store.runtimes[session.id])
        s.store.handle([event(session.id, "UserPromptSubmit", ["prompt": "Hacé un workflow"])])
        #expect(rt.status == .working)
        return (session, rt)
    }

    @Test("Con un workflow andando sigue trabajando, sin aviso, aunque la terminal quede quieta")
    func workflowKeepsWorking() async throws {
        let s = try await Setup()
        let (session, rt) = try working(s)

        s.store.handle([event(session.id, "Stop", workflow)])
        #expect(rt.status == .working)
        #expect(rt.backgroundAgents == 1)
        #expect(!rt.unseen)
        #expect(s.world.notifier.posts.isEmpty)
        #expect(s.store.sessionContext(session.id)?.session.lastMessage == "Lancé el workflow; te aviso cuando termine.")

        // La terminal no muestra nada durante minutos (Claude quieto): la regla del silencio no aplica.
        s.world.advance(5 * 60)
        s.store.tick()
        #expect(rt.status == .working)

        // Claude avisa por inactividad, y los subagentes del workflow siguen usando herramientas.
        s.store.handle([event(session.id, "Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]),
                        event(session.id, "PreToolUse", ["tool_name": "Bash", "agent_id": "wf-agent-1"])])
        #expect(rt.status == .working)
        #expect(s.world.notifier.posts.isEmpty)

        // Termina el workflow: Claude retoma solo y su Stop, ya sin tareas, te deja el turno con aviso.
        s.store.handle([event(session.id, "UserPromptSubmit", ["prompt": "<task-notification>…", "source": "system"])])
        #expect(rt.backgroundAgents == 0)
        s.store.handle([event(session.id, "Stop", ["background_tasks": [], "last_assistant_message": "El workflow terminó: todo listo."])])
        #expect(rt.status == .waiting)
        #expect(rt.unseen)
        #expect(s.world.notifier.posts.last?.body == "El workflow terminó: todo listo.")
    }

    @Test("Con solo un servidor en segundo plano te toca, como siempre")
    func shellOnly() async throws {
        let s = try await Setup()
        let (session, rt) = try working(s)
        s.store.handle([event(session.id, "Stop", ["background_tasks": [["id": "b1", "type": "shell", "status": "running",
                                                                           "command": "php artisan serve"]]])])
        #expect(rt.status == .waiting)
        #expect(rt.backgroundAgents == 0)
        #expect(rt.unseen)
        #expect(s.world.notifier.posts.last?.body == "Terminó; queda 1 tarea en segundo plano")
    }

    @Test("Si el segundo plano no da señales en 15 minutos, te toca y avisa")
    func expires() async throws {
        let s = try await Setup()
        let (session, rt) = try working(s)
        s.store.handle([event(session.id, "Stop", workflow)])

        // Cada evento de un subagente renueva el plazo.
        s.world.advance(10 * 60)
        s.store.handle([event(session.id, "PostToolUse", ["tool_name": "Read", "agent_id": "wf-agent-1"])])
        s.world.advance(10 * 60)
        s.store.tick()
        #expect(rt.status == .working)

        s.world.advance(6 * 60)
        s.store.tick()
        #expect(rt.status == .waiting)
        #expect(rt.backgroundAgents == 0)
        #expect(s.world.notifier.posts.last?.body == BackgroundRule.expiredNotification)
    }

    @Test("Esc no frena el segundo plano; rechazar el permiso de un subagente vuelve a trabajando")
    func escape() async throws {
        let s = try await Setup()
        let (session, rt) = try working(s)
        s.store.handle([event(session.id, "Stop", workflow)])

        s.store.userInput(session.id, [27])
        #expect(rt.status == .working)

        s.store.handle([event(session.id, "PermissionRequest", ["tool_name": "Bash", "agent_id": "wf-agent-2",
                                                                "tool_input": ["command": "rm -rf build"]])])
        #expect(rt.status == .attention)
        s.store.userInput(session.id, [27])
        #expect(rt.status == .working)
        #expect(rt.backgroundAgents == 1)
    }

    @Test("Escribirle mientras el workflow trabaja: el turno nuevo es del agente principal")
    func newPromptWhileInBackground() async throws {
        let s = try await Setup()
        let (session, rt) = try working(s)
        s.store.handle([event(session.id, "Stop", workflow)])

        s.store.handle([event(session.id, "UserPromptSubmit", ["prompt": "¿Cómo va?"])])
        #expect(rt.backgroundAgents == 0)
        // Responde y el workflow sigue: vuelve al segundo plano, sin aviso.
        s.store.handle([event(session.id, "Stop", workflow)])
        #expect(rt.status == .working)
        #expect(rt.backgroundAgents == 1)
        #expect(s.world.notifier.posts.isEmpty)

        // Sin segundo plano, Esc vuelve a cortar como siempre.
        s.store.handle([event(session.id, "UserPromptSubmit", ["prompt": "Otra cosa"])])
        s.store.userInput(session.id, [27])
        #expect(rt.status == .waiting)
    }

    @Test("Reiniciar la sesión olvida el segundo plano")
    func relaunchResets() async throws {
        let s = try await Setup()
        let (session, rt) = try working(s)
        s.store.handle([event(session.id, "Stop", workflow)])
        s.store.relaunch(session.id)
        #expect(rt.backgroundAgents == 0)
    }
}
