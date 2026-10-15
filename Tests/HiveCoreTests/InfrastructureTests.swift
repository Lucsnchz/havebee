import Foundation
import Testing
@testable import HiveCore

@Suite("MCP")
struct MCPTests {
    @Test("Agrega, renombra y quita servidores conservando el resto del archivo")
    func editsKeepOtherFields() throws {
        let dir = TempDir()
        dir.write(".mcp.json", #"{"mcpServers": {"remoto": {"type": "http", "url": "https://x/mcp", "headers": {"A": "1"}}}, "otraCosa": true}"#)
        try MCPConfig.upsert(MCPServer(name: "boost", config: ["command": "php", "args": ["artisan", "boost:mcp"]]), dir: dir.path)
        var servers = MCPConfig.load(dir: dir.path)
        #expect(servers.map(\.name) == ["boost", "remoto"])
        #expect(servers[1].config["headers"]?["A"]?.string == "1") // campo que Hive no conoce
        #expect(servers[1].isRemote && servers[1].summary == "https://x/mcp")
        #expect(servers[0].summary == "php artisan boost:mcp")

        try MCPConfig.upsert(MCPServer(name: "laravel-boost", config: servers[0].config), replacing: "boost", dir: dir.path)
        try MCPConfig.remove("remoto", dir: dir.path)
        servers = MCPConfig.load(dir: dir.path)
        #expect(servers.map(\.name) == ["laravel-boost"])
        let text = try #require(dir.read(".mcp.json"))
        #expect(text.contains("\"otraCosa\": true"))
        #expect(!text.contains("\" : ")) // formato habitual, sin el espacio de JSONSerialization
        #expect(text.contains("https://") == false || text.contains("\\/") == false)
    }

    @Test("Crea el archivo si no existe; un archivo roto o vacío se lee como sin servidores")
    func missingOrBroken() throws {
        let dir = TempDir()
        #expect(MCPConfig.load(dir: dir.path).isEmpty)
        try MCPConfig.remove("nada", dir: dir.path) // no explota
        dir.write(".mcp.json", "{roto")
        #expect(MCPConfig.load(dir: dir.path).isEmpty)
        try MCPConfig.upsert(MCPServer(name: "a", config: ["command": "x"]), dir: dir.path)
        #expect(MCPConfig.load(dir: dir.path).map(\.name) == ["a"])
    }

    @Test("En un worktree sin .mcp.json usa el del repo")
    func effectiveFile() {
        let repo = TempDir()
        let worktree = TempDir()
        #expect(MCPConfig.effectiveFile(directory: worktree.path, projectPath: repo.path) == nil)
        repo.write(".mcp.json", "{}")
        #expect(MCPConfig.effectiveFile(directory: worktree.path, projectPath: repo.path)?.path == repo.url.appendingPathComponent(".mcp.json").path)
        worktree.write(".mcp.json", "{}")
        #expect(MCPConfig.effectiveFile(directory: worktree.path, projectPath: repo.path)?.path == worktree.url.appendingPathComponent(".mcp.json").path)
    }

    @Test("Traducción a opciones de Codex")
    func codex() {
        let args = MCPConfig.codexOverrides([
            MCPServer(name: "herd", config: ["command": "php", "args": ["/ruta con espacios/herd.phar"], "env": ["SITE_PATH": "/code/x", "A": "1"]]),
            MCPServer(name: "docs remotas", config: ["type": "http", "url": "https://docs/mcp"]),
            MCPServer(name: "vacío", config: [:]),
        ])
        #expect(args == [
            "-c", #"mcp_servers.herd.command="php""#,
            "-c", #"mcp_servers.herd.args=["/ruta con espacios/herd.phar"]"#,
            "-c", #"mcp_servers.herd.env={"A"="1","SITE_PATH"="/code/x"}"#,
            "-c", #"mcp_servers.docs_remotas.url="https://docs/mcp""#,
        ])
    }

    @Test("Traducción a los ajustes de Gemini")
    func gemini() throws {
        #expect(MCPConfig.geminiSettings([]) == nil)
        let settings = try #require(MCPConfig.geminiSettings([
            MCPServer(name: "a", config: ["command": "npx", "args": ["-y", "pkg"], "env": ["K": "V"]]),
            MCPServer(name: "b", config: ["url": "https://b/mcp"]),
        ]))
        #expect(settings["mcpServers"]?["a"] == ["command": "npx", "args": ["-y", "pkg"], "env": ["K": "V"]])
        #expect(settings["mcpServers"]?["b"] == ["httpUrl": "https://b/mcp"])
        let dir = TempDir()
        let file = dir.url.appendingPathComponent("sub/gemini.json")
        #expect(MCPConfig.writeGeminiSettings([MCPServer(name: "a", config: ["command": "x"])], to: file) == file.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(MCPConfig.writeGeminiSettings([], to: file) == nil)
    }

    @Test("Detecta rutas que no existen en esta Mac", arguments: [
        ("C:/Users/dev/php.exe", true), (#"D:\tools\x.exe"#, true), ("/no/existe/bin", true),
        ("/bin/sh", false), ("php", false), ("npx", false),
    ])
    func brokenPath(command: String, broken: Bool) {
        #expect((MCPServer(name: "x", config: ["command": .string(command)]).brokenPath != nil) == broken)
        #expect(MCPServer(name: "remoto", config: ["url": "https://x"]).brokenPath == nil)
    }

    @Test("Separa una línea de comando respetando comillas", arguments: [
        ("php artisan boost:mcp", ["php", "artisan", "boost:mcp"]),
        (#"php "/ruta con espacios/x.phar" --flag"#, ["php", "/ruta con espacios/x.phar", "--flag"]),
        ("npx  -y   'paquete raro'", ["npx", "-y", "paquete raro"]),
        (#"cmd """#, ["cmd", ""]),
        ("", []),
    ])
    func split(line: String, words: [String]) {
        #expect(MCPConfig.splitCommandLine(line) == words)
    }

    @Test("MCP globales de Claude, Codex y Gemini")
    func globals() {
        let home = TempDir()
        let codex = TempDir()
        home.write(".claude.json", #"""
        {"mcpServers": {"global": {"command": "npx", "args": ["g"]}},
         "projects": {"/code/x": {"mcpServers": {"local": {"url": "https://l"}}}}}
        """#)
        codex.write("config.toml", """
        model = "x"
        [mcp_servers.firebase]
        command = "node"
        [mcp_servers.firebase.env]
        A = "1"
        [mcp_servers."con comillas"]
        url = "https://q"
        [otra]
        command = "no"
        """)
        home.write(".gemini/settings.json", #"{"mcpServers": {"gem": {"command": "g"}}}"#)
        let groups = MCPConfig.globals(projectPath: "/code/x", home: home.url, codexHome: codex.url)
        #expect(groups.map(\.id) == ["claude-user", "claude-local", "codex", "gemini"])
        #expect(groups[0].servers == [.init(name: "global", summary: "npx g")])
        #expect(groups[1].servers == [.init(name: "local", summary: "https://l")])
        #expect(groups[2].servers == [.init(name: "firebase", summary: "node"), .init(name: "con comillas", summary: "https://q")])
        #expect(MCPConfig.globals(projectPath: "/otro", home: TempDir().url, codexHome: TempDir().url).isEmpty)
    }

    @Test("Catálogo según el stack del proyecto")
    func catalog() {
        let home = TempDir()
        let laravel = TempDir()
        laravel.write("artisan")
        laravel.write("package.json", #"{"devDependencies": {"vite": "1"}}"#)
        var names = MCPCatalog.suggestions(projectPath: laravel.path, home: home.url, existing: []).map(\.name)
        #expect(names == ["laravel-boost", "nightwatch", "playwright", "chrome-devtools", "context7"])

        home.write("Library/Application Support/Herd/bin/herd-mcp.phar")
        let withHerd = MCPCatalog.suggestions(projectPath: laravel.path, home: home.url, existing: [])
        #expect(withHerd.map(\.name).contains("herd"))
        #expect(withHerd.first { $0.name == "herd" }?.config["env"]?["SITE_PATH"]?.string == laravel.path)

        let next = TempDir()
        next.write("package.json", #"{"dependencies": {"next": "15"}}"#)
        #expect(MCPCatalog.suggestions(projectPath: next.path, home: home.url, existing: []).map(\.name).first == "next-devtools")

        let android = TempDir()
        android.write("gradlew")
        #expect(MCPCatalog.suggestions(projectPath: android.path, home: home.url, existing: []).map(\.name) == ["mobile-mcp", "context7"])

        let xcode = TempDir()
        _ = xcode.subdir("App.xcodeproj")
        #expect(MCPCatalog.suggestions(projectPath: xcode.path, home: home.url, existing: []).map(\.name) == ["XcodeBuildMCP", "context7"])

        // Lo que ya está (por nombre o por comando) no se sugiere.
        let existing = [MCPServer(name: "boost", config: ["command": "php", "args": ["artisan", "boost:mcp"]]),
                        MCPServer(name: "context7", config: ["command": "otro"])]
        names = MCPCatalog.suggestions(projectPath: laravel.path, home: TempDir().url, existing: existing).map(\.name)
        #expect(!names.contains("laravel-boost") && !names.contains("context7"))
    }
}

@Suite("Historial")
struct HistoryStoreTests {
    @Test("Guarda mensajes en orden, en JSONL y en Markdown")
    func appendAndLoad() throws {
        let dir = TempDir()
        let store = HistoryStore(directory: dir.url.appendingPathComponent("history"))
        let session = Session(name: "Claude 1", kind: .claude)
        store.ensureMarkdown(session: session, place: "demo › main")
        store.ensureMarkdown(session: session, place: "otro lugar") // no lo pisa
        store.append(HistoryEntry(date: .reference, role: .user, text: "¿Cómo se llama la tabla?"), sessionId: session.id, agentName: "Claude Code")
        store.append(HistoryEntry(date: .reference, role: .assistant, text: "Se llama `orders`."), sessionId: session.id, agentName: "Claude Code")
        store.append(HistoryEntry(date: .reference, role: .marker, text: "/clear"), sessionId: session.id, agentName: "Claude Code")

        let entries = store.load(session.id)
        #expect(entries.map(\.role) == [.user, .assistant, .marker])
        #expect(entries.map(\.text) == ["¿Cómo se llama la tabla?", "Se llama `orders`.", "/clear"])
        let markdown = try String(contentsOf: store.markdownURL(session.id), encoding: .utf8)
        #expect(markdown.hasPrefix("# Historial de «Claude 1» (demo › main)"))
        #expect(markdown.contains("## Vos · "))
        #expect(markdown.contains("## Claude Code · "))
        #expect(markdown.contains("> **/clear · "))
        #expect(markdown.components(separatedBy: "# Historial").count == 2) // un solo encabezado
    }

    @Test("Cada marcador explica lo suyo: /compact no es un contexto limpio")
    func markers() throws {
        let dir = TempDir()
        let store = HistoryStore(directory: dir.url)
        let id = UUID()
        for text in ["/clear", "/compact", "⚠︎ Se cortó: rate_limit", "Nueva conversación"] {
            store.append(HistoryEntry(date: .reference, role: .marker, text: text), sessionId: id, agentName: "Claude Code")
        }
        store.append(HistoryEntry(date: .reference, role: .system, text: "<task-notification>listo</task-notification>"),
                     sessionId: id, agentName: "Claude Code")
        let markdown = try String(contentsOf: store.markdownURL(id), encoding: .utf8)
        let blocks = markdown.components(separatedBy: "> **").dropFirst()
        #expect(blocks.count == 4)
        let byMarker = Dictionary(uniqueKeysWithValues: blocks.map { block in
            (String(block.prefix { $0 != "·" }).trimmingCharacters(in: .whitespaces), block)
        })
        #expect(byMarker["/clear"]?.contains("contexto limpio") == true)
        #expect(byMarker["/compact"]?.contains("Se compactó el contexto") == true)
        #expect(byMarker["/compact"]?.contains("contexto limpio") == false)
        #expect(byMarker["⚠︎ Se cortó: rate_limit"]?.contains("contexto limpio") == false)
        #expect(byMarker["Nueva conversación"]?.contains("contexto limpio") == true)
        #expect(markdown.contains("## Aviso automático · "))
        #expect(store.load(id).last?.role == .system)
    }

    @Test("Sin historial devuelve vacío; las líneas rotas se saltean")
    func corruptLines() throws {
        let dir = TempDir()
        let store = HistoryStore(directory: dir.url)
        let id = UUID()
        #expect(store.load(id).isEmpty)
        store.append(HistoryEntry(date: .reference, role: .user, text: "hola"), sessionId: id, agentName: "Codex")
        let handle = try FileHandle(forWritingTo: store.jsonlURL(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{basura\n".utf8))
        try handle.close()
        store.append(HistoryEntry(date: .reference, role: .assistant, text: "chau"), sessionId: id, agentName: "Codex")
        #expect(store.load(id).map(\.text) == ["hola", "chau"])
    }

    @Test("Se borra con la sesión")
    func delete() {
        let dir = TempDir()
        let store = HistoryStore(directory: dir.url)
        let session = Session(name: "x", kind: .codex)
        store.ensureMarkdown(session: session, place: "p")
        store.append(HistoryEntry(date: .reference, role: .user, text: "x"), sessionId: session.id, agentName: "Codex")
        store.delete(session.id)
        #expect(!FileManager.default.fileExists(atPath: store.markdownURL(session.id).path))
        #expect(!FileManager.default.fileExists(atPath: store.jsonlURL(session.id).path))
    }

    @Test("El aviso para la IA dice dónde está el archivo y que no lo lea de entrada")
    func hint() {
        let hint = HistoryStore.agentHint(markdown: URL(fileURLWithPath: "/a b/x.md"))
        #expect(hint.contains("/a b/x.md"))
        #expect(hint.contains("No lo leas por defecto"))
    }
}

@Suite("Estado guardado")
struct StateStoreTests {
    @Test("Primera vez, guardar y leer")
    func roundTrip() throws {
        let dir = TempDir()
        let store = StateStore(file: dir.url.appendingPathComponent("sub/state.json"))
        #expect(store.load() == .empty)
        let state = HiveState(projects: [.make(), .scratch(home: "/h")], selection: nil, expanded: [])
        try store.save(state)
        #expect(store.load() == .loaded(state))
    }

    @Test("Un archivo roto se aparta sin perderlo")
    func corrupted() throws {
        let dir = TempDir()
        let file = dir.write("state.json", "{esto no es un estado")
        let store = StateStore(file: file)
        guard case .corrupted(let backup) = store.load(now: .reference) else {
            Issue.record("Esperaba un estado roto")
            return
        }
        #expect(backup.lastPathComponent == "state-1790000000.bak.json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{esto no es un estado")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.load() == .empty)
    }
}

@Suite("Puente de eventos")
struct EventBridgeTests {
    /// La carpeta temporal tiene que vivir lo mismo que el test (si se suelta, se borra).
    struct Installed {
        let dir: TempDir
        let paths: HivePaths
    }

    func install() throws -> Installed {
        let dir = TempDir()
        let paths = HivePaths(root: dir.url.appendingPathComponent("Application Support/Hive")) // con espacio, como en la Mac real
        try EventBridge.install(paths: paths)
        return Installed(dir: dir, paths: paths)
    }

    @Test("Instala el script ejecutable y los hooks de Claude")
    func installs() throws {
        let installed = try install()
        defer { withExtendedLifetime(installed) {} }
        let paths = installed.paths
        #expect(FileManager.default.isExecutableFile(atPath: paths.eventBin.path))
        let settings = try #require(JSONValue.parse(try Data(contentsOf: paths.claudeSettings)))
        let hooks = try #require(settings["hooks"]?.object)
        #expect(Set(hooks.keys) == Set(EventBridge.claudeHookEvents + EventBridge.claudeToolEvents))
        let stop = hooks["Stop"]?.array?.first?["hooks"]?.array?.first
        #expect(stop?["command"]?.string == #""${HIVE_EVENT_BIN:-true}" claude Stop"#)
        #expect(hooks["PreToolUse"]?.array?.first?["matcher"]?.string == "*")
    }

    @Test("Escribe también los ajustes con el statusLine de Hive; los de siempre no lo tienen")
    func installsUsageSettings() throws {
        let installed = try install()
        defer { withExtendedLifetime(installed) {} }
        let paths = installed.paths
        let plain = try #require(JSONValue.parse(try Data(contentsOf: paths.claudeSettings)))
        let usage = try #require(JSONValue.parse(try Data(contentsOf: paths.claudeSettingsWithUsage)))
        #expect(plain["statusLine"] == nil)
        #expect(usage["hooks"] == plain["hooks"])
        #expect(usage["statusLine"]?["type"]?.string == "command")
        #expect(usage["statusLine"]?["command"]?.string == #""${HIVE_EVENT_BIN:-true}" claude-status"#)
        #expect(paths.claudeSettingsWithUsage.lastPathComponent == "claude-settings-usage.json")
        #expect(paths.usageDir.path == paths.root.appendingPathComponent("usage").path)
    }

    static let statusPayload = #"{"session_id":"c-1","model":{"id":"claude-opus-4-1","display_name":"Opus"},"context_window":{"context_window_size":200000,"used_percentage":34.4,"remaining_percentage":65.6},"rate_limits":{"five_hour":{"used_percentage":23,"resets_at":1790003600},"seven_day":{"used_percentage":41.6,"resets_at":1790500000}}}"#

    @Test("claude-status guarda lo que manda Claude y muestra el resumen")
    func claudeStatus() throws {
        let installed = try install()
        defer { withExtendedLifetime(installed) {} }
        let paths = installed.paths
        let id = UUID()
        let r = runScript(paths, args: ["claude-status"], stdin: Self.statusPayload, sessionId: id)
        #expect(r.ok)
        #expect(r.stdout == "ctx 34% · 5h 23% · sem 42%")
        let saved = try String(contentsOf: paths.usageDir.appendingPathComponent("\(id.uuidString).json"), encoding: .utf8)
        #expect(saved == Self.statusPayload)
        // Sin temporales sueltos ni eventos: el statusLine no es un evento.
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.usageDir.path) == ["\(id.uuidString).json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.eventsDir.path).isEmpty)
        // Solo lo que venga: sin límites (API key) muestra solo el contexto.
        let partial = runScript(paths, args: ["claude-status"], stdin: #"{"context_window":{"used_percentage":7}}"#, sessionId: id)
        #expect(partial.stdout == "ctx 7%")
        let nothing = runScript(paths, args: ["claude-status"], stdin: "{}", sessionId: id)
        #expect(nothing.ok && nothing.stdout.isEmpty)
    }

    @Test("claude-status encadena tu statusLine con el mismo stdin")
    func claudeStatusChained() throws {
        let installed = try install()
        defer { withExtendedLifetime(installed) {} }
        let (dir, paths) = (installed.dir, installed.paths)
        let id = UUID()
        let received = dir.url.appendingPathComponent("recibido.json").path
        let r = runScript(paths, args: ["claude-status"], stdin: Self.statusPayload, sessionId: id,
                          extra: ["HIVE_USER_STATUSLINE": "cat > \(shellQuote(received)); printf 'mi barra'"])
        #expect(r.ok)
        #expect(r.stdout == "mi barra")
        #expect(try String(contentsOfFile: received, encoding: .utf8) == Self.statusPayload)
        // Hive guarda el uso igual.
        #expect(FileManager.default.fileExists(atPath: paths.usageDir.appendingPathComponent("\(id.uuidString).json").path))
    }

    @Test("claude-status fuera de Hive no escribe nada")
    func claudeStatusOutsideHive() throws {
        let installed = try install()
        defer { withExtendedLifetime(installed) {} }
        let r = ProcessCommandRunner().run("/bin/sh", ["-c", "printf '{}' | \(shellQuote(installed.paths.eventBin.path)) claude-status"],
                                           cwd: nil, environment: ["HIVE_SESSION_ID": "", "HIVE_EVENTS_DIR": ""])
        #expect(r.ok && r.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installed.paths.usageDir.path))
    }

    func runScript(_ paths: HivePaths, args: [String], stdin: String = "", sessionId: UUID, extra: [String: String] = [:]) -> CommandResult {
        let script = "printf '%s' \(shellQuote(stdin)) | " + ([paths.eventBin.path] + args).map(shellQuote).joined(separator: " ")
        return ProcessCommandRunner().run("/bin/sh", ["-c", script], cwd: nil, environment: [
            "HIVE_EVENTS_DIR": paths.eventsDir.path, "HIVE_SESSION_ID": sessionId.uuidString,
        ].merging(extra) { _, new in new })
    }

    @Test("El script deja eventos de Claude y de Codex que el lector entiende, en orden")
    func scriptAndWatcher() throws {
        let installed = try install()
        defer { withExtendedLifetime(installed) {} }
        let (dir, paths) = (installed.dir, installed.paths)
        let id = UUID()
        #expect(runScript(paths, args: ["claude", "Stop"], stdin: #"{"last_assistant_message": "Listo"}"#, sessionId: id).ok)
        // Codex: el notify original se sigue llamando con el mismo payload.
        let chained = dir.url.appendingPathComponent("encadenado.txt").path
        let payload = #"{"type":"agent-turn-complete","thread-id":"t-1"}"#
        #expect(runScript(paths, args: ["codex", "/bin/sh", "-c", "printf '%s' \"$1\" > \(shellQuote(chained))", "sh", payload], sessionId: id).ok)
        #expect(runScript(paths, args: ["desconocido", "x"], sessionId: id).ok)

        let received = Locked<[HiveEvent]>([])
        let watcher = EventWatcher(directory: paths.eventsDir) { events in received.mutate { $0 += events } }
        let events = watcher.drain()
        #expect(events.map(\.name) == ["Stop", "notify"])
        #expect(events[0].payload["last_assistant_message"]?.string == "Listo")
        #expect(events[1].payload["thread-id"]?.string == "t-1")
        #expect(received.value.count == 2)
        #expect(watcher.drain().isEmpty) // se borraron al leerlos
        // El encadenado corre en segundo plano.
        var chainedText: String?
        for _ in 0..<50 where chainedText == nil {
            chainedText = try? String(contentsOfFile: chained, encoding: .utf8)
            if chainedText == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(chainedText == payload)
    }

    @Test("Sin sesión o sin carpeta el script no hace nada")
    func scriptWithoutEnvironment() throws {
        let installed = try install()
        defer { withExtendedLifetime(installed) {} }
        let paths = installed.paths
        let r = ProcessCommandRunner().run(paths.eventBin.path, ["claude", "Stop"], cwd: nil, environment: ["HIVE_SESSION_ID": "", "HIVE_EVENTS_DIR": ""])
        #expect(r.ok)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.eventsDir.path).isEmpty)
    }

    @Test("Ignora archivos a medio escribir y borra los viejos al arrancar")
    func watcherIgnoresTemporaryFiles() throws {
        let installed = try install()
        defer { withExtendedLifetime(installed) {} }
        let paths = installed.paths
        try "\(UUID().uuidString)\tclaude\tStop\n{}".write(to: paths.eventsDir.appendingPathComponent("tmp.abc123"), atomically: true, encoding: .utf8)
        try "basura".write(to: paths.eventsDir.appendingPathComponent("x.evt"), atomically: true, encoding: .utf8)
        let watcher = EventWatcher(directory: paths.eventsDir) { _ in }
        #expect(watcher.drain().isEmpty) // el .evt roto se descarta, el temporal se deja
        #expect(FileManager.default.fileExists(atPath: paths.eventsDir.appendingPathComponent("tmp.abc123").path))
        watcher.purge()
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.eventsDir.path).isEmpty)
    }
}

/// Caja con candado para juntar resultados desde closures `@Sendable`.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

@Suite("Conversaciones previas de los agentes")
struct AgentStorageTests {
    func storage() -> (AgentStorage, claude: TempDir, codex: TempDir, gemini: TempDir) {
        let claude = TempDir(), codex = TempDir(), gemini = TempDir()
        return (AgentStorage(claudeConfigDir: claude.url, codexHome: codex.url, geminiHome: gemini.url), claude, codex, gemini)
    }

    @Test("Sabe si Claude ya guardó una conversación")
    func claude() {
        let (storage, claude, _, _) = storage()
        #expect(!storage.claudeConversationExists("abc"))
        claude.write("projects/-code-demo/abc.jsonl", "{}")
        #expect(storage.claudeConversationExists("abc"))
        #expect(!storage.claudeConversationExists("otro"))
    }

    @Test("Lee el notify configurado en Codex")
    func codexNotify() {
        let (storage, _, codex, _) = storage()
        #expect(storage.codexExistingNotify() == nil)
        codex.write("config.toml", #"notify = ["/x", "y"]"#)
        #expect(storage.codexExistingNotify() == ["/x", "y"])
    }

    @Test("Encuentra el thread de Codex de esa carpeta, el más cercano al arranque y sin repetir")
    func codexThread() throws {
        let (storage, _, codex, _) = storage()
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!)
        func rollout(_ name: String, id: String, cwd: String, modified: Date) throws {
            let file = codex.write("\(day)/\(name).jsonl", #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"# + "\n{}")
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        try rollout("a", id: "viejo", cwd: "/code/x", modified: now.addingTimeInterval(-3600))
        try rollout("b", id: "otra-carpeta", cwd: "/code/y", modified: now)
        try rollout("c", id: "bueno", cwd: "/code/x", modified: now.addingTimeInterval(-10))
        try rollout("d", id: "tomado", cwd: "/code/x", modified: now)
        let since = now.addingTimeInterval(-60)
        // Sin fecha de creación en el session_meta, cuenta la de modificación.
        #expect(storage.discoverCodexThread(cwd: "/code/x", since: since, excluding: ["tomado"], now: now) == "bueno")
        #expect(storage.discoverCodexThread(cwd: "/code/x", since: since, excluding: [], now: now) == "bueno")
        #expect(storage.discoverCodexThread(cwd: "/code/x", since: since, excluding: ["bueno"], now: now) == "tomado")
        #expect(storage.discoverCodexThread(cwd: "/code/z", since: since, excluding: [], now: now) == nil)
    }

    @Test("Encuentra la sesión de Gemini por el hash de la carpeta")
    func geminiSession() throws {
        let (storage, _, _, gemini) = storage()
        let hash = AgentStorage.sha256("/code/x")
        let since = Date().addingTimeInterval(-60)
        gemini.write("tmp/\(hash)/chats/session-1.json", #"{"sessionId": "g-1", "projectHash": "\#(hash)"}"#)
        gemini.write("tmp/otro/chats/session-2.json", #"{"sessionId": "g-2", "projectHash": "otro"}"#)
        gemini.write("tmp/\(hash)/chats/session-3.json", #"{"sessionId": "g-3"}"#) // sin hash: vale la carpeta
        let found = storage.discoverGeminiSession(cwd: "/code/x", since: since, excluding: [])
        #expect(found == "g-1" || found == "g-3")
        #expect(storage.discoverGeminiSession(cwd: "/code/x", since: since, excluding: ["g-1", "g-3"]) == nil)
        #expect(storage.discoverGeminiSession(cwd: "/code/x", since: Date().addingTimeInterval(3600), excluding: []) == nil)
        #expect(AgentStorage.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Encuentra tu statusLine de Claude: el del repo le gana al global")
    func userStatusLine() {
        let (storage, claude, _, _) = storage()
        let repo = TempDir()
        #expect(storage.claudeUserStatusLine(directory: repo.path) == nil)
        claude.write("settings.json", #"{"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}"#)
        #expect(storage.claudeUserStatusLine(directory: repo.path) == "~/.claude/statusline.sh")
        repo.write(".claude/settings.json", #"{"statusLine": {"type": "command", "command": "npx ccstatusline"}}"#)
        #expect(storage.claudeUserStatusLine(directory: repo.path) == "npx ccstatusline")
        repo.write(".claude/settings.local.json", #"{"statusLine": {"command": "  echo local  "}}"#)
        #expect(storage.claudeUserStatusLine(directory: repo.path) == "echo local")
        // Uno roto, vacío o el propio de Hive no cuentan.
        repo.write(".claude/settings.local.json", #"{"statusLine": {"type": "command", "command": "\"${HIVE_EVENT_BIN:-true}\" claude-status"}}"#)
        repo.write(".claude/settings.json", "{roto")
        #expect(storage.claudeUserStatusLine(directory: repo.path) == "~/.claude/statusline.sh")
    }

    @Test("Gemini: gana el chat que empezó más cerca del arranque")
    func geminiStartTime() throws {
        let (storage, _, _, gemini) = storage()
        let hash = AgentStorage.sha256("/code/x")
        let since = Date().addingTimeInterval(-600)
        func chat(_ name: String, id: String, started: Date) {
            let stamp = started.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            gemini.write("tmp/\(hash)/chats/\(name).json", #"{"sessionId": "\#(id)", "projectHash": "\#(hash)", "startTime": "\#(stamp)"}"#)
        }
        chat("session-a", id: "propio", started: since.addingTimeInterval(4))
        chat("session-b", id: "otra-terminal", started: since.addingTimeInterval(300)) // se modificó después, pero empezó más tarde
        chat("session-c", id: "anterior", started: since.addingTimeInterval(-3600))  // de antes del arranque
        #expect(storage.discoverGeminiSession(cwd: "/code/x", since: since, excluding: []) == "propio")
        #expect(storage.discoverGeminiSession(cwd: "/code/x", since: since, excluding: ["propio"]) == "otra-terminal")
        #expect(storage.discoverGeminiSession(cwd: "/code/x", since: since, excluding: ["propio", "otra-terminal"]) == nil)
    }

    @Test("Usa las variables de entorno de cada agente")
    func live() {
        let storage = AgentStorage.live(environment: ["CLAUDE_CONFIG_DIR": "/c", "CODEX_HOME": "/x"], home: URL(fileURLWithPath: "/h"))
        #expect(storage.claudeConfigDir.path == "/c")
        #expect(storage.codexHome.path == "/x")
        #expect(storage.geminiHome.path == "/h/.gemini")
        let defaults = AgentStorage.live(environment: [:], home: URL(fileURLWithPath: "/h"))
        #expect(defaults.claudeConfigDir.path == "/h/.claude" && defaults.codexHome.path == "/h/.codex")
    }
}
