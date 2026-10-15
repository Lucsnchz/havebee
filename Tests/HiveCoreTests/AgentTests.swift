import Foundation
import Testing
@testable import HiveCore

@Suite("Eventos de los agentes")
struct AgentEventTests {
    let id = UUID()

    func event(_ source: String, _ name: String, _ payload: JSONValue = [:]) -> HiveEvent {
        HiveEvent(sessionId: id, source: source, name: name, payload: payload)
    }

    func interpret(_ e: HiveEvent, status: SessionStatus = .idle, agentId: String? = "actual") -> AgentEventOutcome {
        AgentEventInterpreter.interpret(e, status: status, agentSessionId: agentId)
    }

    @Test("Lee el archivo .evt que escribe el puente")
    func parse() throws {
        let text = "\(id.uuidString)\tclaude\tStop\n{\"last_assistant_message\": \"Listo\"}"
        let e = try #require(HiveEvent.parse(text))
        #expect(e.sessionId == id && e.source == "claude" && e.name == "Stop")
        #expect(e.payload["last_assistant_message"]?.string == "Listo")

        let noPayload = try #require(HiveEvent.parse("\(id.uuidString)\tcodex\tnotify"))
        #expect(noPayload.payload == .object([:]))
        let badJSON = try #require(HiveEvent.parse("\(id.uuidString)\tclaude\tStop\n{roto"))
        #expect(badJSON.payload == .object([:]))
        #expect(HiveEvent.parse("no-es-uuid\tclaude\tStop") == nil)
        #expect(HiveEvent.parse("\(id.uuidString)\tclaude") == nil)
        #expect(HiveEvent.parse("") == nil)
    }

    @Test("SessionStart: guarda el nuevo ID y marca /clear y /compact")
    func sessionStart() {
        let started = interpret(event("claude", "SessionStart", ["session_id": "nuevo", "source": "startup"]))
        #expect(started.agentSessionId == "nuevo")
        #expect(started.history.isEmpty)
        #expect(started.status == nil)

        let same = interpret(event("claude", "SessionStart", ["session_id": "actual", "source": "resume"]))
        #expect(same.agentSessionId == nil)

        let cleared = interpret(event("claude", "SessionStart", ["session_id": "otro", "source": "clear"]))
        #expect(cleared.history.map(\.role) == [.marker])
        #expect(cleared.history.first?.text == "/clear")
        let compacted = interpret(event("claude", "SessionStart", ["source": "compact"]))
        #expect(compacted.history.first?.text == "/compact")
    }

    @Test("UserPromptSubmit: trabajando y guarda lo que escribiste")
    func prompt() {
        let o = interpret(event("claude", "UserPromptSubmit", ["prompt": "  Arreglá el login  "]))
        #expect(o.status == .working)
        #expect(o.touchesActivity)
        #expect(o.history.map(\.text) == ["Arreglá el login"])
        #expect(o.history.map(\.role) == [.user])
        #expect(o.notification == nil)
    }

    @Test("Herramientas: trabajando, sin historial")
    func tools() {
        for name in ["PreToolUse", "PostToolUse"] {
            let o = interpret(event("claude", name, ["tool_name": "Bash"]))
            #expect(o.status == .working)
            #expect(o.history.isEmpty && !o.touchesActivity)
        }
    }

    @Test("Notification: permiso → necesita permiso con aviso", arguments: [
        (["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"] as JSONValue, "Claude needs your permission to use Bash"),
        (["notification_type": "elicitation_dialog"] as JSONValue, AgentEventInterpreter.permissionNotification),
        (["message": "Needs permission to write"] as JSONValue, "Needs permission to write"),
    ])
    func permission(payload: JSONValue, expected: String) {
        let o = interpret(event("claude", "Notification", payload))
        #expect(o.status == .attention)
        #expect(o.notification == expected)
    }

    @Test("Notification de espera: solo cambia si estaba trabajando")
    func idleNotification() {
        let payload: JSONValue = ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]
        let working = interpret(event("claude", "Notification", payload), status: .working)
        #expect(working.status == .waiting)
        #expect(working.notification == "Claude is waiting for your input")
        let waiting = interpret(event("claude", "Notification", payload), status: .waiting)
        #expect(waiting.status == nil)
        let silent = interpret(event("claude", "Notification", ["notification_type": "idle_prompt"]), status: .working)
        #expect(silent.status == .waiting && silent.notification == nil)
    }

    @Test("Stop: te toca, con la respuesta en el aviso, la tarjeta y el historial")
    func stop() {
        let long = String(repeating: "palabra ", count: 60)
        let o = interpret(event("claude", "Stop", ["last_assistant_message": .string("Listo.\n\nArreglé   el bug. " + long)]))
        #expect(o.status == .waiting)
        #expect(o.touchesActivity)
        #expect(o.history.map(\.role) == [.assistant])
        #expect(o.history.first?.text.hasPrefix("Listo.\n\nArreglé") == true) // el historial guarda el texto completo
        let reply = o.reply ?? ""
        #expect(reply.hasPrefix("Listo. Arreglé el bug."))           // la tarjeta lo aplana
        #expect(reply.count == 201 && reply.hasSuffix("…"))
        #expect(o.notification == reply)

        let empty = interpret(event("claude", "Stop"))
        #expect(empty.status == .waiting)
        #expect(empty.reply == nil && empty.history.isEmpty)
        #expect(empty.notification == AgentEventInterpreter.defaultNotification)
    }

    @Test("Codex: turno terminado con lo que pediste y lo que respondió")
    func codexTurn() {
        let o = interpret(event("codex", "notify", [
            "type": "agent-turn-complete", "thread-id": "t-1",
            "input-messages": ["Primero", "Segundo"], "last-assistant-message": "Hecho",
        ]), agentId: nil)
        #expect(o.status == .waiting)
        #expect(o.agentSessionId == "t-1")
        #expect(o.history.map(\.role) == [.user, .assistant]) // sin marca: es el primer thread
        #expect(o.history[0].text == "Primero\n\nSegundo")
        #expect(o.reply == "Hecho" && o.notification == "Hecho")
    }

    @Test("Codex: un thread nuevo en la misma sesión marca una conversación nueva")
    func codexNewThread() {
        let o = interpret(event("codex", "notify", ["type": "agent-turn-complete", "thread-id": "t-2"]), agentId: "t-1")
        #expect(o.agentSessionId == "t-2")
        #expect(o.history.first?.role == .marker)
        #expect(o.notification == AgentEventInterpreter.defaultNotification)

        let same = interpret(event("codex", "notify", ["thread-id": "t-1"]), agentId: "t-1")
        #expect(same.agentSessionId == nil && same.history.isEmpty && same.status == nil)
    }

    @Test("Eventos desconocidos no hacen nada")
    func unknown() {
        #expect(interpret(event("claude", "SubagentStop")) == AgentEventOutcome())
        #expect(interpret(event("gemini", "algo")) == AgentEventOutcome())
    }

    @Test("Resumen en una línea", arguments: [
        (nil, nil), ("", nil), ("   \n ", nil), ("Hola\n\nmundo", "Hola mundo"),
    ] as [(String?, String?)])
    func summary(input: String?, expected: String?) {
        #expect(AgentEventInterpreter.summary(input) == expected)
    }
}

@Suite("Regla del silencio")
struct SilenceRuleTests {
    let start = Date.reference

    @Test("Mientras hay salida reciente sigue trabajando")
    func stillWorking() {
        let v = SilenceRule.evaluate(now: start.addingTimeInterval(10), workingSince: start, lastOutput: start.addingTimeInterval(8), hooksSeen: false)
        #expect(!v.stopWorking)
    }

    @Test("Después de 6 segundos en silencio deja de trabajar")
    func stops() {
        let v = SilenceRule.evaluate(now: start.addingTimeInterval(20), workingSince: start, lastOutput: start.addingTimeInterval(2), hooksSeen: true)
        #expect(v.stopWorking)
        #expect(!v.notify) // con hooks, el aviso lo da el evento del agente
    }

    @Test("Avisa solo si trabajó un rato y el agente no tiene eventos")
    func notify() {
        let busy = SilenceRule.evaluate(now: start.addingTimeInterval(30), workingSince: start, lastOutput: start.addingTimeInterval(10), hooksSeen: false)
        #expect(busy.stopWorking && busy.notify)
        // Un Enter en el prompt vacío: casi no hubo salida, no molesta con un aviso.
        let blip = SilenceRule.evaluate(now: start.addingTimeInterval(30), workingSince: start, lastOutput: start.addingTimeInterval(1), hooksSeen: false)
        #expect(blip.stopWorking && !blip.notify)
    }

    @Test("Sin salida desde que arrancó cuenta desde que empezó a trabajar")
    func noOutputSinceStart() {
        let early = SilenceRule.evaluate(now: start.addingTimeInterval(3), workingSince: start, lastOutput: .distantPast, hooksSeen: false)
        #expect(!early.stopWorking)
        let late = SilenceRule.evaluate(now: start.addingTimeInterval(7), workingSince: start, lastOutput: .distantPast, hooksSeen: false)
        #expect(late.stopWorking && !late.notify)
        let unknownStart = SilenceRule.evaluate(now: start, workingSince: nil, lastOutput: .distantPast, hooksSeen: false)
        #expect(!unknownStart.stopWorking)
    }
}

@Suite("Cómo se lanza cada sesión")
struct LaunchPlannerTests {
    let paths = HivePaths(root: URL(fileURLWithPath: "/datos/Hive"))
    let project = Project(name: "ecommerce", path: "/code/ecommerce")
    let branch = Branch(name: "main", mode: .main)

    func context(_ kind: SessionKind, agentId: String? = nil, configure: (inout LaunchContext) -> Void = { _ in }) -> LaunchContext {
        var ctx = LaunchContext(
            session: Session(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, name: "Claude 1", kind: kind, agentSessionId: agentId),
            project: project, branch: branch, directory: "/code/ecommerce", path: "/bin:/usr/bin",
            inheritedEnvironment: ["HOME": "/Users/yo", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "WarpTerminal",
                                   "SHLVL": "3", "HIVE_SESSION_ID": "viejo", "LANG": "es_AR.UTF-8", "CODEX_SANDBOX": "seatbelt"],
            paths: paths, newAgentId: "nuevo-id")
        configure(&ctx)
        return ctx
    }

    @Test("Terminal: el shell del usuario como login")
    func shell() {
        let plan = LaunchPlanner.plan(context(.shell))
        #expect(plan.binary == nil)
        #expect(plan.args == ["-l"])
        #expect(plan.agentSessionId == nil)
    }

    @Test("Entorno limpio con las variables de Hive")
    func environment() {
        let env = LaunchPlanner.plan(context(.shell)).environment
        #expect(env["HIVE_SESSION_ID"] == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(env["HIVE_EVENTS_DIR"] == "/datos/Hive/events")
        #expect(env["HIVE_EVENT_BIN"] == "/datos/Hive/bin/hive-event")
        #expect(env["HIVE_PROJECT"] == "ecommerce" && env["HIVE_BRANCH"] == "main")
        #expect(env["PATH"] == "/bin:/usr/bin")
        #expect(env["PWD"] == "/code/ecommerce")
        #expect(env["TERM"] == "xterm-256color" && env["COLORTERM"] == "truecolor" && env["TERM_PROGRAM"] == "Hive")
        #expect(env["LANG"] == "es_AR.UTF-8") // se respeta el idioma que ya tenías
        #expect(env["HOME"] == "/Users/yo")
        // Lo heredado de otra terminal o de otro agente se descarta.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "SHLVL", "CODEX_SANDBOX"] { #expect(env[key] == nil) }
        #expect(LaunchPlanner.plan(context(.shell)).environmentList.first == "COLORTERM=truecolor") // ordenado
    }

    @Test("Claude nuevo: ID propio, nombre, hooks, aviso del historial y terminal normal")
    func claudeNew() throws {
        let plan = LaunchPlanner.plan(context(.claude))
        #expect(plan.binary == "claude")
        #expect(plan.agentSessionId == "nuevo-id")
        #expect(Array(plan.args.prefix(4)) == ["--session-id", "nuevo-id", "--name", "Claude 1"])
        let settings = try #require(plan.args.firstIndex(of: "--settings"))
        #expect(plan.args[settings + 1] == "/datos/Hive/claude-settings.json")
        let hint = try #require(plan.args.firstIndex(of: "--append-system-prompt"))
        #expect(plan.args[hint + 1].contains("/datos/Hive/history/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.md"))
        #expect(plan.environment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] == "1")
        #expect(!plan.args.contains("--mcp-config"))
    }

    @Test("Claude reanuda su conversación si ya existe")
    func claudeResume() {
        let plan = LaunchPlanner.plan(context(.claude, agentId: "previo") { $0.claudeConversationExists = true })
        #expect(Array(plan.args.prefix(2)) == ["--resume", "previo"])
        #expect(plan.agentSessionId == "previo")
        // Con ID pero sin conversación guardada (nunca recibió un mensaje): arranca con ese ID.
        let fresh = LaunchPlanner.plan(context(.claude, agentId: "previo"))
        #expect(Array(fresh.args.prefix(2)) == ["--session-id", "previo"])
    }

    @Test("Claude respeta los ajustes")
    func claudeSettings() {
        let plan = LaunchPlanner.plan(context(.claude) { $0.claudeInline = false; $0.historyHint = false })
        #expect(!plan.args.contains("--append-system-prompt"))
        #expect(plan.environment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] == nil)
    }

    @Test("Claude recibe el .mcp.json del repo solo si su carpeta no lo tiene")
    func claudeMCP() {
        let fromRepo = LaunchPlanner.plan(context(.claude) {
            $0.directory = "/code/ecommerce.worktrees/x"
            $0.mcpFile = URL(fileURLWithPath: "/code/ecommerce/.mcp.json")
        })
        #expect(fromRepo.args.suffix(2) == ["--mcp-config", "/code/ecommerce/.mcp.json"])
        let own = LaunchPlanner.plan(context(.claude) { $0.mcpFile = URL(fileURLWithPath: "/code/ecommerce/.mcp.json") })
        #expect(!own.args.contains("--mcp-config"))
    }

    @Test("Codex nuevo: notify encadenado, MCP del proyecto y aviso del historial")
    func codexNew() throws {
        let plan = LaunchPlanner.plan(context(.codex) {
            $0.codexExistingNotify = ["/apps/otro", "turn-ended"]
            $0.mcpServers = [MCPServer(name: "laravel-boost", config: ["command": "php", "args": ["artisan", "boost:mcp"]])]
        })
        #expect(plan.binary == "codex")
        #expect(plan.agentSessionId == nil)
        #expect(plan.args.first == "-c")
        #expect(plan.args[1] == #"notify=["/datos/Hive/bin/hive-event", "codex", "/apps/otro", "turn-ended"]"#)
        #expect(plan.args.contains(#"mcp_servers.laravel-boost.command="php""#))
        #expect(plan.args.contains(where: { $0.hasPrefix("developer_instructions=\"Hive guarda el historial") }))
        #expect(!plan.args.contains("resume"))
    }

    @Test("Codex reanuda: «resume» primero, opciones y el thread al final")
    func codexResume() {
        let known = LaunchPlanner.plan(context(.codex, agentId: "t-1") { $0.historyHint = false; $0.claudeInline = false })
        #expect(known.args.first == "resume")
        #expect(known.args.last == "t-1")
        #expect(known.args.count == 4) // resume, -c, notify, thread
        let discovered = LaunchPlanner.plan(context(.codex) { $0.discoveredAgentId = "t-9" })
        #expect(discovered.args.first == "resume" && discovered.args.last == "t-9")
        #expect(discovered.agentSessionId == "t-9")
    }

    @Test("Gemini: reanuda lo encontrado y recibe los MCP por sus ajustes")
    func gemini() {
        let plan = LaunchPlanner.plan(context(.gemini) {
            $0.discoveredAgentId = "g-2"
            $0.geminiSettingsPath = "/datos/Hive/gemini/x.json"
        })
        #expect(plan.binary == "gemini")
        #expect(plan.args == ["--resume", "g-2"])
        #expect(plan.agentSessionId == "g-2")
        #expect(plan.environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] == "/datos/Hive/gemini/x.json")
        // Gemini no reporta su conversación: no se le da el aviso del historial.
        #expect(!plan.args.contains("--append-system-prompt"))
        let fresh = LaunchPlanner.plan(context(.gemini))
        #expect(fresh.args.isEmpty)
    }
}

@Suite("Notify de Codex y TOML")
struct CodexConfigTests {
    @Test("Lee el notify de nivel superior del config.toml")
    func existingNotify() {
        #expect(CodexNotify.existing(inConfig: #"""
        model = "x"
        notify = ["/apps/Otro App/bin", "turn-ended"] # comentario
        [mcp_servers.a]
        notify = ["no", "es este"]
        """#) == ["/apps/Otro App/bin", "turn-ended"])
        #expect(CodexNotify.existing(inConfig: "[tabla]\nnotify = [\"x\"]") == nil)
        #expect(CodexNotify.existing(inConfig: "notifyx = [\"x\"]") == nil)
        #expect(CodexNotify.existing(inConfig: "") == nil)
    }

    @Test("Arma el notify con el puente primero")
    func override() {
        #expect(CodexNotify.override(eventBin: "/a b/hive-event", existing: nil) == #"notify=["/a b/hive-event", "codex"]"#)
        #expect(CodexNotify.override(eventBin: "/h", existing: ["x"]) == #"notify=["/h", "codex", "x"]"#)
    }

    @Test("Textos y claves de TOML")
    func toml() {
        #expect(TOML.string(#"dice "hola" en C:\dir"#) == #""dice \"hola\" en C:\\dir""#)
        #expect(TOML.string("dos\nlíneas\tcon tab") == #""dos\nlíneas\tcon tab""#)
        #expect(TOML.bareKey("laravel-boost") == "laravel-boost")
        #expect(TOML.bareKey("mi server.v2") == "mi_server_v2")
    }

    @Test("Limpia el entorno heredado")
    func baseEnvironment() {
        let env = SessionEnvironment.base(inherited: ["CLAUDE_CODE_SSE_PORT": "1", "ITERM_PROFILE": "x", "__CFBundleIdentifier": "a", "OLDPWD": "/", "KEEP": "sí"],
                                          directory: "/d", path: "/p")
        #expect(env.keys.sorted() == ["COLORTERM", "KEEP", "LANG", "PATH", "PWD", "TERM", "TERM_PROGRAM"])
        #expect(env["LANG"] == "en_US.UTF-8")
    }
}
