import Foundation
import Testing
@testable import HiveCore

@Suite("Grok: lanzamiento, sesiones, hooks y eventos")
struct GrokTests {
    let paths = HivePaths(root: URL(fileURLWithPath: "/datos/Hive"))

    func context(agentId: String? = nil, configure: (inout LaunchContext) -> Void = { _ in }) -> LaunchContext {
        var ctx = LaunchContext(
            session: Session(name: "Grok 1", kind: .grok, agentSessionId: agentId),
            project: Project(name: "app", path: "/code/app"), branch: Branch(name: "main", mode: .main),
            directory: "/code/app", path: "/bin:/usr/bin", inheritedEnvironment: ["HOME": "/Users/yo"],
            paths: paths, historyHint: true, newAgentId: "0f6c1b52-0000-4000-8000-000000000001")
        configure(&ctx)
        return ctx
    }

    func run(_ name: String, _ payload: JSONValue = [:], status: SessionStatus = .working, agentId: String? = "actual",
             inBackground: Bool = false) -> AgentEventOutcome {
        AgentEventInterpreter.interpret(HiveEvent(sessionId: UUID(), source: "grok", name: name, payload: payload),
                                        status: status, agentSessionId: agentId, inBackground: inBackground)
    }

    // MARK: - Modelo y lanzamiento

    @Test("Grok es un agente más: binario, nombre e instalación")
    func kind() {
        #expect(SessionKind.allCases == [.claude, .codex, .gemini, .grok, .shell])
        #expect(SessionKind.grok.isAgent)
        #expect(SessionKind.grok.binary == "grok")
        #expect(SessionKind.grok.label == "Grok")
        #expect(SessionKind.grok.defaultName == "Grok")
        #expect(SessionKind.grok.installHint == "curl -fsSL https://x.ai/cli/install.sh | bash")
        // Una sesión guardada con Grok se lee de vuelta.
        let session = Session(name: "Grok 1", kind: .grok, agentSessionId: "abc")
        let data = try! JSONEncoder().encode(session)
        #expect(try! JSONDecoder().decode(Session.self, from: data).kind == .grok)
    }

    @Test("Nueva: arranca con su ID y sin pantalla alternativa; con la sesión guardada, la retoma")
    func launch() {
        let fresh = LaunchPlanner.plan(context())
        #expect(fresh.binary == "grok")
        #expect(fresh.args == ["--session-id", "0f6c1b52-0000-4000-8000-000000000001", "--no-alt-screen"])
        #expect(fresh.agentSessionId == "0f6c1b52-0000-4000-8000-000000000001")
        // El puente de eventos va en el entorno: los hooks personales lo llaman.
        #expect(fresh.environment["HIVE_EVENT_BIN"] == paths.eventBin.path)
        #expect(fresh.environment["HIVE_EVENTS_DIR"] == paths.eventsDir.path)
        #expect(fresh.environment["HIVE_SESSION_ID"] != nil)

        // Ya la lanzamos con ese ID pero nunca le escribiste: se vuelve a crear con el mismo.
        #expect(LaunchPlanner.plan(context(agentId: "g-1")).args == ["--session-id", "g-1", "--no-alt-screen"])
        let resumed = LaunchPlanner.plan(context(agentId: "g-1") { $0.grokConversationExists = true })
        #expect(resumed.args == ["--resume", "g-1", "--no-alt-screen"])
        #expect(resumed.agentSessionId == "g-1")

        // Con el ajuste de la pantalla alternativa apagado, Grok usa la suya.
        #expect(LaunchPlanner.plan(context { $0.claudeInline = false }).args == ["--session-id", "0f6c1b52-0000-4000-8000-000000000001"])
        // No recibe la ayuda del historial (no avisa sus mensajes completos).
        #expect(!fresh.args.contains("--append-system-prompt"))
    }

    // MARK: - Sesiones guardadas

    @Test("Encuentra la sesión guardada en ~/.grok/sessions, en cualquier carpeta de proyecto")
    func sessionExists() {
        let root = TempDir("hive-grok")
        let agents = AgentStorage(claudeConfigDir: root.subdir("claude"), codexHome: root.subdir("codex"),
                                  geminiHome: root.subdir("gemini"), grokHome: root.subdir(".grok"))
        #expect(!agents.grokSessionExists("4b1e9c0a-1111-4222-8333-444455556666")) // sin carpeta de sesiones
        root.write(".grok/sessions/-Users-yo-code-app/4b1e9c0a-1111-4222-8333-444455556666/summary.json", "{}")
        root.write(".grok/sessions/-Users-yo-code-app/4b1e9c0a-1111-4222-8333-444455556666/updates.jsonl", "")
        root.write(".grok/sessions/otro/7777.jsonl", "")
        #expect(agents.grokSessionExists("4b1e9c0a-1111-4222-8333-444455556666"))
        #expect(agents.grokSessionExists("4B1E9C0A-1111-4222-8333-444455556666"))
        #expect(agents.grokSessionExists("7777")) // también como archivo
        #expect(!agents.grokSessionExists("4b1e9c0a"))
        #expect(!agents.grokSessionExists(""))
        #expect(!agents.grokSessionExists("ffffffff-1111-4222-8333-444455556666"))
    }

    @Test("Sin carpeta de Grok explícita, va al lado de la de Gemini (en los tests, dentro de la temporal)")
    func defaultHome() {
        let agents = AgentStorage(claudeConfigDir: URL(fileURLWithPath: "/t/claude"), codexHome: URL(fileURLWithPath: "/t/codex"),
                                  geminiHome: URL(fileURLWithPath: "/t/gemini"))
        #expect(agents.grokHome.path == "/t/grok")
        let live = AgentStorage.live(environment: [:], home: URL(fileURLWithPath: "/Users/yo"))
        #expect(live.grokHome.path == "/Users/yo/.grok")
    }

    // MARK: - Hooks

    @Test("Instala los hooks personales de Grok una sola vez y los repone si cambian")
    func installsHooks() throws {
        let root = TempDir("hive-grok-hooks")
        let agents = AgentStorage(claudeConfigDir: root.subdir("claude"), codexHome: root.subdir("codex"),
                                  geminiHome: root.subdir("gemini"), grokHome: root.url.appendingPathComponent(".grok"))
        #expect(agents.installGrokHooks() == nil)
        let file = root.url.appendingPathComponent(".grok/hooks/hive.json")
        let json = try #require(JSONValue.parse(try Data(contentsOf: file)))
        let hooks = try #require(json["hooks"]?.object)
        #expect(Set(hooks.keys) == Set(EventBridge.grokEvents))
        for event in EventBridge.grokEvents {
            let hook = hooks[event]?.array?.first?["hooks"]?.array?.first
            #expect(hook?["type"]?.string == "command")
            #expect(hook?["command"]?.string == "\"${HIVE_EVENT_BIN:-true}\" grok \(event)")
            // Sin matcher: corren con todas las herramientas.
            #expect(hooks[event]?.array?.first?["matcher"] == nil)
        }

        // Si no cambió, no lo vuelve a escribir.
        let date = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        #expect(agents.installGrokHooks() == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) == date)

        // Si lo tocaste, lo repone.
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        #expect(agents.installGrokHooks() == nil)
        #expect(JSONValue.parse(try Data(contentsOf: file))?["hooks"]?.object?.count == EventBridge.grokEvents.count)
    }

    @Test("Si no puede escribir los hooks, devuelve el error y no se cae")
    func hooksError() {
        let root = TempDir("hive-grok-ro")
        root.write("grok-es-un-archivo", "x")
        let agents = AgentStorage(claudeConfigDir: root.subdir("claude"), codexHome: root.subdir("codex"),
                                  geminiHome: root.subdir("gemini"), grokHome: root.url.appendingPathComponent("grok-es-un-archivo"))
        #expect(agents.installGrokHooks() != nil)
    }

    @Test("LaunchContextBuilder instala los hooks solo para Grok y ve si la sesión ya existe")
    func builder() {
        let root = TempDir("hive-grok-builder")
        let repo = root.subdir("repo").path
        let agents = AgentStorage(claudeConfigDir: root.subdir("claude"), codexHome: root.subdir("codex"),
                                  geminiHome: root.subdir("gemini"), grokHome: root.url.appendingPathComponent(".grok"))
        func build(_ kind: SessionKind, agentId: String? = nil) -> LaunchContext {
            LaunchContextBuilder(session: Session(name: "S", kind: kind, agentSessionId: agentId), project: Project(name: "app", path: repo),
                                 branch: Branch(name: "main", mode: .main), directory: repo, path: "/bin",
                                 inheritedEnvironment: [:], paths: HivePaths(root: root.url.appendingPathComponent("Hive")),
                                 agents: agents, historyHint: false).build()
        }
        let hooks = root.url.appendingPathComponent(".grok/hooks/hive.json")
        _ = build(.claude)
        #expect(!FileManager.default.fileExists(atPath: hooks.path))
        #expect(!build(.grok, agentId: "g-1").grokConversationExists)
        #expect(FileManager.default.fileExists(atPath: hooks.path))
        root.write(".grok/sessions/x/g-1/summary.json", "{}")
        #expect(build(.grok, agentId: "g-1").grokConversationExists)
        #expect(!build(.claude, agentId: "g-1").grokConversationExists)
    }

    // MARK: - Eventos

    @Test("Turno: el prompt trabaja y queda en el historial; las herramientas confirman que trabaja")
    func turn() {
        let prompt = run("UserPromptSubmit", ["hookEventName": "UserPromptSubmit", "sessionId": "actual", "prompt": "Arreglá el login"],
                         status: .waiting)
        #expect(prompt.status == .working)
        #expect(prompt.touchesActivity)
        #expect(prompt.history.map(\.text) == ["Arreglá el login"])
        #expect(prompt.history.map(\.role) == [.user])
        #expect(prompt.backgroundAgents == 0)

        for name in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
            #expect(run(name, ["toolName": "Bash", "toolInput": ["command": "ls"]], status: .waiting).status == .working, "\(name)")
        }
        // Un subagente no te saca de tu turno.
        #expect(run("PreToolUse", ["toolName": "Read", "agentId": "sub-1"], status: .waiting).status == nil)
        #expect(run("PreToolUse", ["toolName": "Read", "agent_id": "sub-1"], status: .working).status == .working)
    }

    @Test("Stop: te toca, con su respuesta si la manda y el aviso de siempre si no")
    func stop() {
        let withReply = run("Stop", ["lastAssistantMessage": "Listo, arreglé el login."])
        #expect(withReply.status == .waiting)
        #expect(withReply.notification == "Listo, arreglé el login.")
        #expect(withReply.reply == "Listo, arreglé el login.")
        #expect(withReply.history.map(\.role) == [.assistant])
        #expect(withReply.touchesActivity)
        #expect(run("Stop", ["last_assistant_message": "Hecho"]).notification == "Hecho")

        let bare = run("Stop", ["hookEventName": "Stop", "sessionId": "actual"])
        #expect(bare.status == .waiting)
        #expect(bare.notification == AgentEventInterpreter.defaultNotification)
        #expect(bare.history.isEmpty)

        // Con subagentes en segundo plano sigue trabajando, como en Claude.
        let background = run("Stop", ["background_tasks": [["type": "subagent", "status": "running"]]])
        #expect(background.status == .working)
        #expect(background.notification == nil)
        #expect(background.backgroundAgents == 1)
    }

    @Test("Cortes: un error de la API pide que hagas algo; cancelarlo vos no avisa")
    func failures() {
        let failure = run("StopFailure", ["error": "overloaded"])
        #expect(failure.status == .attention)
        #expect(failure.notification == "xAI está saturado: reintentá")
        #expect(failure.history.map(\.text) == ["⚠︎ Se cortó: overloaded"])
        #expect(run("StopFailure", ["error": ["type": "rate_limit"]]).notification == "Llegaste al límite de uso")
        #expect(run("StopFailure").notification == "Se cortó por un error")

        let cancelled = run("StopCancelled")
        #expect(cancelled.status == .waiting)
        #expect(cancelled.notification == nil)
    }

    @Test("Avisos: un pedido de permiso, la inactividad y lo informativo")
    func notifications() {
        let permission = run("Notification", ["message": "Grok needs your permission to use Bash"])
        #expect(permission.status == .attention)
        #expect(permission.notification == "Grok needs your permission to use Bash")
        #expect(run("Notification", ["notificationType": "permission_prompt"]).notification == AgentEventInterpreter.permissionNotification)
        // Ya pedía permiso: nada nuevo.
        #expect(run("Notification", ["notificationType": "permission_prompt"], status: .attention).status == nil)

        #expect(run("Notification", ["message": "Grok is waiting for your input"]).status == .waiting)
        #expect(run("Notification", ["message": "Grok is waiting for your input"], inBackground: true).status == nil)
        #expect(run("Notification", ["message": "Grok is waiting for your input"], status: .waiting).status == nil)
        #expect(run("Notification", ["notification_type": "auth_success", "message": "ok"]).status == nil)
    }

    @Test("SessionStart guarda el ID que manda Grok, en camelCase o snake_case")
    func sessionStart() {
        #expect(run("SessionStart", ["sessionId": "nuevo"]).agentSessionId == "nuevo")
        #expect(run("SessionStart", ["session_id": "nuevo"]).agentSessionId == "nuevo")
        #expect(run("SessionStart", ["sessionId": "actual"]).agentSessionId == nil)
        #expect(run("SessionStart", [:]).agentSessionId == nil)
        // Un evento desconocido no hace nada.
        #expect(run("SubagentStart", ["agentId": "x"]) == AgentEventOutcome())
    }

    @Test("El puente deja los eventos de Grok con su origen")
    func bridge() throws {
        let dir = TempDir()
        let paths = HivePaths(root: dir.url.appendingPathComponent("Application Support/Hive"))
        try EventBridge.install(paths: paths)
        let id = UUID()
        let script = "printf '%s' '{\"sessionId\":\"g-1\"}' | " + [paths.eventBin.path, "grok", "Stop"].map(shellQuote).joined(separator: " ")
        let r = ProcessCommandRunner().run("/bin/sh", ["-c", script], cwd: nil, environment: [
            "HIVE_EVENTS_DIR": paths.eventsDir.path, "HIVE_SESSION_ID": id.uuidString,
        ])
        #expect(r.ok)
        let events = EventWatcher(directory: paths.eventsDir) { _ in }.drain()
        #expect(events.count == 1)
        #expect(events.first?.source == "grok")
        #expect(events.first?.name == "Stop")
        #expect(events.first?.sessionId == id)
        #expect(events.first?.payload["sessionId"]?.string == "g-1")
    }
}
