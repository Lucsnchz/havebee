import Foundation
import Testing
@testable import HiveCore

/// Hooks de Claude 2.1.x que Hive suma: StopFailure, PermissionRequest, PostToolUseFailure,
/// subagentes, tareas en segundo plano y mensajes automáticos.
@Suite("Hooks nuevos de Claude")
struct AgentHooksTests {
    func run(_ name: String, _ payload: JSONValue = [:], status: SessionStatus = .working, agentId: String? = "actual") -> AgentEventOutcome {
        AgentEventInterpreter.interpret(HiveEvent(sessionId: UUID(), source: "claude", name: name, payload: payload),
                                        status: status, agentSessionId: agentId)
    }

    @Test("StopFailure: necesita que hagas algo, con el motivo en español", arguments: [
        ("rate_limit", "Llegaste al límite de uso"),
        ("overloaded", "Anthropic está saturado: reintentá"),
        ("server_error", "Anthropic está saturado: reintentá"),
        ("authentication_failed", "Tenés que volver a iniciar sesión (/login)"),
        ("oauth_org_not_allowed", "Tenés que volver a iniciar sesión (/login)"),
        ("max_output_tokens", "La respuesta se cortó (límite de tokens)"),
        ("billing_error", "Problema de facturación"),
        ("invalid_request", "Se cortó por un error"),
        ("unknown", "Se cortó por un error"),
    ])
    func stopFailure(error: String, text: String) {
        let o = run("StopFailure", ["error": .string(error), "error_details": "429"])
        #expect(o.status == .attention)
        #expect(o.notification == text)
        #expect(o.reply == text)
        #expect(o.touchesActivity)
        #expect(o.history.map(\.role) == [.marker])
        #expect(o.history.first?.text == "⚠︎ Se cortó: \(error)")
    }

    @Test("StopFailure guarda la respuesta a medias y el transcript")
    func stopFailurePartial() throws {
        let o = run("StopFailure", ["error": "rate_limit", "last_assistant_message": "Empecé a migrar…",
                                    "session_id": "c-1", "transcript_path": "/t/c-1.jsonl"])
        #expect(o.history.map(\.role) == [.assistant, .marker])
        #expect(o.history.map(\.text) == ["Empecé a migrar…", "⚠︎ Se cortó: rate_limit"])
        let transcript = try #require(o.transcript)
        #expect(transcript.conversationId == "c-1" && transcript.path == "/t/c-1.jsonl")
        // Sin el campo `error` (o con otro formato) igual avisa.
        #expect(run("StopFailure").notification == "Se cortó por un error")
        #expect(run("StopFailure", ["error": ["type": "overloaded"]]).notification == "Anthropic está saturado: reintentá")
    }

    @Test("PermissionRequest: pide permiso al instante con un texto en español", arguments: [
        (["tool_name": "Bash", "tool_input": ["command": "npm test"]] as JSONValue, "Pide permiso para Bash: npm test"),
        (["tool_name": "Edit", "cwd": "/code/x", "tool_input": ["file_path": "/code/x/app/Models/User.php"]] as JSONValue,
         "Pide permiso para editar app/Models/User.php"),
        (["tool_name": "Write", "tool_input": ["file_path": "/otro/lado.txt"]] as JSONValue, "Pide permiso para editar /otro/lado.txt"),
        (["tool_name": "WebFetch", "tool_input": ["url": "https://laravel.com"]] as JSONValue, "Pide permiso para abrir https://laravel.com"),
        (["tool_name": "mcp__laravel-boost__database-query", "tool_input": [:]] as JSONValue,
         "Pide permiso para usar database-query (MCP laravel-boost)"),
        (["tool_name": "Task"] as JSONValue, "Pide permiso para Task"),
        ([:] as JSONValue, AgentEventInterpreter.permissionNotification),
    ])
    func permissionRequest(payload: JSONValue, text: String) {
        for status in [SessionStatus.working, .waiting, .idle] {
            let o = run("PermissionRequest", payload, status: status)
            #expect(o.status == .attention)
            #expect(o.notification == text)
            #expect(o.history.isEmpty && !o.touchesActivity)
        }
    }

    @Test("Un comando largo de Bash se resume en una línea")
    func longCommand() {
        let command = "php artisan migrate --force && " + String(repeating: "echo hola && ", count: 20) + "\n  echo fin"
        let text = AgentEventInterpreter.permissionText(toolName: "Bash", input: ["command": .string(command)])
        #expect(text.hasPrefix("Pide permiso para Bash: php artisan migrate --force && echo hola"))
        #expect(!text.contains("\n"))
        #expect(text.hasSuffix("…"))
    }

    @Test("PostToolUse y UserPromptSubmit sacan de «Necesita permiso»")
    func leavesAttention() {
        #expect(run("PostToolUse", ["tool_name": "Bash"], status: .attention).status == .working)
        #expect(run("UserPromptSubmit", ["prompt": "dale"], status: .attention).status == .working)
        // Después del permiso, el Notification permission_prompt de los 6 s no hace nada.
        #expect(run("Notification", ["notification_type": "permission_prompt", "message": "x"], status: .attention) == AgentEventOutcome())
    }

    @Test("PostToolUseFailure: si lo cortaste con Esc te toca; si no, sigue trabajando")
    func toolFailure() {
        #expect(run("PostToolUseFailure", ["tool_name": "Bash", "is_interrupt": true], status: .attention).status == .waiting)
        #expect(run("PostToolUseFailure", ["tool_name": "Bash", "is_interrupt": true], status: .working).notification == nil)
        #expect(run("PostToolUseFailure", ["tool_name": "Bash", "error": "exit 1"], status: .attention).status == .working)
        #expect(run("PostToolUseFailure", ["tool_name": "Bash", "is_interrupt": false], status: .waiting).status == .working)
    }

    @Test("Con agent_id (subagente) las herramientas solo confirman que sigue trabajando", arguments: [
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
    ])
    func subagentTools(name: String) {
        let payload: JSONValue = ["tool_name": "Read", "agent_id": "sub-1"]
        #expect(run(name, payload, status: .working).status == .working)
        for status in [SessionStatus.waiting, .idle, .attention] {
            #expect(run(name, payload, status: status).status == nil, "\(name) en \(status)")
        }
        // Un Esc dentro de un subagente no dice nada del principal.
        #expect(run("PostToolUseFailure", ["agent_id": "sub-1", "is_interrupt": true], status: .working).status == nil)
    }

    @Test("Stop con tareas en segundo plano: te toca, pero avisa que quedan", arguments: [
        (["background_tasks": [["id": "a"], ["id": "b"]]] as JSONValue, "Terminó; quedan 2 tareas en segundo plano"),
        (["background_tasks": [["id": "a"]]] as JSONValue, "Terminó; queda 1 tarea en segundo plano"),
        (["background_tasks": .number(3)] as JSONValue, "Terminó; quedan 3 tareas en segundo plano"),
        (["background_tasks": [] as JSONValue, "last_assistant_message": "Listo"] as JSONValue, "Listo"),
    ])
    func backgroundTasks(payload: JSONValue, text: String) {
        let o = run("Stop", payload)
        #expect(o.status == .waiting)
        #expect(o.notification == text)
    }

    @Test("Un background_tasks con un número absurdo no hace caer a Hive")
    func backgroundTasksOutOfRange() {
        #expect(AgentEventInterpreter.backgroundTaskCount(.number(1e300)) == 10_000)
        #expect(AgentEventInterpreter.backgroundTaskCount(.number(-3)) == 0)
        #expect(AgentEventInterpreter.backgroundTaskCount(.number(2.9)) == 2)
        #expect(run("Stop", ["background_tasks": .number(1e300)]).status == .waiting)
    }

    @Test("Un prompt automático (source ≠ user) trabaja pero no cuenta como tuyo", arguments: [
        "system", "loop_wakeup", "schedule_wakeup", "poll_event", "sdk",
    ])
    func automaticPrompt(source: String) {
        let o = run("UserPromptSubmit", ["prompt": "<task-notification>Terminó el build</task-notification>", "source": .string(source)],
                    status: .waiting)
        #expect(o.status == .working)
        #expect(o.history.map(\.role) == [.system])
        #expect(!o.touchesActivity)
        let mine = run("UserPromptSubmit", ["prompt": "Hacé el login", "source": "user"], status: .waiting)
        #expect(mine.history.map(\.role) == [.user] && mine.touchesActivity)
    }

    @Test("SessionStart y Stop informan el transcript de la conversación")
    func transcript() throws {
        let start = run("SessionStart", ["session_id": "nuevo", "source": "startup", "transcript_path": "/c/nuevo.jsonl"])
        #expect(start.transcript?.conversationId == "nuevo")
        #expect(start.transcript?.path == "/c/nuevo.jsonl")
        // Sin session_id en el payload, usa la conversación actual.
        let stop = run("Stop", ["transcript_path": "/c/actual.jsonl"])
        #expect(stop.transcript?.conversationId == "actual")
        #expect(run("Stop", [:]).transcript == nil)
        #expect(run("SessionStart", ["session_id": "x", "transcript_path": ""]).transcript == nil)
    }

    @Test("Los hooks nuevos quedan registrados en los ajustes de Claude")
    func registered() throws {
        let hooks = try #require(EventBridge.claudeSettings["hooks"]?.object)
        for name in ["StopFailure", "PermissionRequest", "PostToolUse", "PostToolUseFailure"] {
            #expect(hooks[name] != nil, "falta \(name)")
        }
        #expect(hooks["PermissionRequest"]?.array?.first?["matcher"]?.string == "*")
        #expect(hooks["PostToolUse"]?.array?.first?["matcher"]?.string == "*")
        #expect(hooks["StopFailure"]?.array?.first?["hooks"]?.array?.first?["command"]?.string == #""${HIVE_EVENT_BIN:-true}" claude StopFailure"#)
    }
}
