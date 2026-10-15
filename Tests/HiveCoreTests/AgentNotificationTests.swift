import Foundation
import Testing
@testable import HiveCore

/// Cada `notification_type` de Claude 2.1.x en cada estado posible de la sesión.
@Suite("Notification de Claude por tipo y estado")
struct AgentNotificationTests {
    static let states: [SessionStatus] = [.idle, .working, .waiting, .attention]

    func notify(_ type: String?, message: String = "Mensaje", status: SessionStatus) -> AgentEventOutcome {
        var payload: [String: JSONValue] = ["message": .string(message)]
        if let type { payload["notification_type"] = .string(type) }
        let event = HiveEvent(sessionId: UUID(), source: "claude", name: "Notification", payload: .object(payload))
        return AgentEventInterpreter.interpret(event, status: status, agentSessionId: "actual")
    }

    @Test("Los que piden algo pasan a «Necesita permiso» con aviso", arguments: [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "worker_permission_prompt", "agent_needs_input",
    ])
    func attention(type: String) {
        for status in Self.states where status != .attention {
            let o = notify(type, message: "Reviewer needs your input", status: status)
            #expect(o.status == .attention, "\(type) en \(status)")
            #expect(o.notification == "Reviewer needs your input")
            #expect(o.history.isEmpty)
        }
        // Ya pedía permiso (por ejemplo, por PermissionRequest): no hace nada.
        #expect(notify(type, status: .attention) == AgentEventOutcome())
        // Sin mensaje, el aviso genérico en español.
        #expect(notify(type, message: "", status: .working).notification == AgentEventInterpreter.permissionNotification)
    }

    @Test("idle_prompt solo pasa de trabajando a tu turno")
    func idle() {
        for status in Self.states {
            let o = notify("idle_prompt", message: "Claude is waiting for your input", status: status)
            if status == .working {
                #expect(o.status == .waiting && o.notification == "Claude is waiting for your input")
            } else {
                #expect(o == AgentEventOutcome(), "idle_prompt en \(status)")
            }
        }
    }

    @Test("Los avisos del sistema no cambian el estado ni avisan", arguments: [
        "agent_completed", "push_notification", "computer_use_enter", "computer_use_exit", "quota_auto_resume_scheduled",
        "quota_auto_resume_done", "model_refusal_fallback", "auth_success", "auth_storage_failure", "plugin_notification",
        "algo_nuevo_que_no_conocemos",
    ])
    func informative(type: String) {
        for status in Self.states {
            let o = notify(type, message: "Claude is using your computer · press Esc to stop", status: status)
            #expect(o == AgentEventOutcome(), "\(type) en \(status)")
        }
    }

    @Test("La palabra «permission» es el respaldo solo para tipos desconocidos")
    func permissionFallback() {
        #expect(notify("tipo_nuevo", message: "Needs permission to write", status: .working).status == .attention)
        #expect(notify(nil, message: "Claude needs your permission to use Bash", status: .idle).status == .attention)
        // Un tipo conocido que menciona «permission» sigue siendo informativo.
        #expect(notify("auth_success", message: "permission granted", status: .working) == AgentEventOutcome())
        // Sin tipo y sin «permission» (versiones viejas): se trata como espera.
        #expect(notify(nil, message: "Claude is waiting for your input", status: .working).status == .waiting)
        #expect(notify(nil, message: "Claude is waiting for your input", status: .waiting).status == nil)
    }
}
