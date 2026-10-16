import Foundation
import Testing
@testable import HiveCore

@Suite("Trabajo en segundo plano (background_tasks del Stop)")
struct BackgroundWorkTests {
    func run(_ name: String, _ payload: JSONValue = [:], status: SessionStatus = .working,
             inBackground: Bool = false) -> AgentEventOutcome {
        AgentEventInterpreter.interpret(HiveEvent(sessionId: UUID(), source: "claude", name: name, payload: payload),
                                        status: status, agentSessionId: "actual", inBackground: inBackground)
    }

    func task(_ type: String, status: String = "running") -> JSONValue {
        ["id": .string(UUID().uuidString), "type": .string(type), "status": .string(status), "description": "x"]
    }

    @Test("Separa subagentes y workflows de shells y monitores")
    func parse() {
        let tasks: JSONValue = .array([task("subagent"), task("workflow"), task("shell"), task("monitor"),
                                       task("local_agent"), task("local_workflow"), task("in_process_teammate"),
                                       task("MCP task"), ["id": "sin-tipo"]])
        #expect(BackgroundWork.parse(tasks) == BackgroundWork(agents: 5, others: 4))
        #expect(BackgroundWork.parse(.array([])) == BackgroundWork())
        #expect(BackgroundWork.parse(nil) == BackgroundWork())
        #expect(BackgroundWork.parse(.string("raro")) == BackgroundWork())
        // Un objeto con las tareas como valores, y la cantidad sola de versiones viejas.
        #expect(BackgroundWork.parse(["a": task("workflow"), "b": task("shell")]) == BackgroundWork(agents: 1, others: 1))
        #expect(BackgroundWork.parse(.number(2)) == BackgroundWork(others: 2))
        #expect(BackgroundWork.parse(.number(.nan)) == BackgroundWork())
    }

    @Test("Lo que ya terminó no cuenta", arguments: ["completed", "failed", "killed", "stopped", "Cancelled"])
    func finished(status: String) {
        #expect(BackgroundWork.parse(.array([task("workflow", status: status)])).total == 0)
        #expect(BackgroundWork.parse(.array([task("workflow", status: "pending")])).agents == 1)
    }

    @Test("Stop con un workflow o subagentes en segundo plano: sigue trabajando y no avisa", arguments: [
        "workflow", "subagent", "local_agent",
    ])
    func stopWithAgents(type: String) {
        let o = run("Stop", ["background_tasks": .array([task(type), task("shell")]), "last_assistant_message": "Lancé el workflow"])
        #expect(o.status == .working)
        #expect(o.notification == nil)
        #expect(o.backgroundAgents == 1)
        // La respuesta igual queda en la tarjeta y en el historial.
        #expect(o.reply == "Lancé el workflow")
        #expect(o.history.map(\.text) == ["Lancé el workflow"])
        #expect(o.touchesActivity)
    }

    @Test("Stop con solo un shell o un monitor (un servidor, por ejemplo): te toca y avisa que quedan")
    func stopWithShells() {
        let o = run("Stop", ["background_tasks": .array([task("shell"), task("monitor")]), "last_assistant_message": "Listo"])
        #expect(o.status == .waiting)
        #expect(o.notification == "Terminó; quedan 2 tareas en segundo plano")
        #expect(o.backgroundAgents == 0)
    }

    @Test("Stop sin nada en segundo plano: te toca con su respuesta")
    func stopClean() {
        let o = run("Stop", ["background_tasks": .array([]), "last_assistant_message": "Terminé"], inBackground: true)
        #expect(o.status == .waiting)
        #expect(o.notification == "Terminé")
        #expect(o.backgroundAgents == 0)
    }

    @Test("Un turno nuevo del agente principal deja de ser segundo plano; los subagentes no")
    func mainTurnResets() {
        #expect(run("UserPromptSubmit", ["prompt": "hola"], inBackground: true).backgroundAgents == 0)
        #expect(run("UserPromptSubmit", ["prompt": "<task-notification>", "source": "system"], inBackground: true).backgroundAgents == 0)
        #expect(run("PreToolUse", ["tool_name": "Read"], inBackground: true).backgroundAgents == 0)
        #expect(run("StopFailure", ["error": "rate_limit"], inBackground: true).backgroundAgents == 0)
        // Un subagente usando herramientas confirma que sigue trabajando, sin tocar el segundo plano.
        let sub = run("PreToolUse", ["tool_name": "Read", "agent_id": "sub-1"], inBackground: true)
        #expect(sub.status == .working)
        #expect(sub.backgroundAgents == nil)
        #expect(run("Notification", ["notification_type": "permission_prompt"], inBackground: true).backgroundAgents == nil)
    }

    @Test("«Esperando tu respuesta» por inactividad no aplica con trabajo en segundo plano")
    func idleWhileInBackground() {
        let idle: JSONValue = ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]
        #expect(run("Notification", idle, inBackground: true).status == nil)
        #expect(run("Notification", idle).status == .waiting)
        // Un pedido de permiso de un subagente sí te necesita.
        #expect(run("Notification", ["notification_type": "permission_prompt", "message": "Permiso"], inBackground: true).status == .attention)
    }

    @Test("El respaldo suelta el segundo plano recién después de 15 minutos sin eventos")
    func rule() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(!BackgroundRule.expired(now: t0.addingTimeInterval(14 * 60), lastEvent: t0))
        #expect(BackgroundRule.expired(now: t0.addingTimeInterval(15 * 60 + 1), lastEvent: t0))
    }
}
