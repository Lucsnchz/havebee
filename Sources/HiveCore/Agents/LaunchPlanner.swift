import Foundation

/// Cómo se lanza una sesión: qué programa, con qué argumentos y qué entorno.
public struct LaunchPlan: Equatable, Sendable {
    /// Nombre del binario a buscar en el PATH, o nil para el shell del usuario.
    public var binary: String?
    public var args: [String]
    public var environment: [String: String]
    /// ID de conversación que queda asociado a la sesión.
    public var agentSessionId: String?

    /// Solo se dibuja en Hive, nunca se manda al proceso como entrada ni como argumentos.
    public var restoredHistory: [HistoryEntry] = []

    public var environmentList: [String] {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

/// Lo que hace falta saber para lanzar una sesión. Las búsquedas en disco (conversaciones previas,
/// MCP, notify de Codex) las hace quien arma el contexto; el planificador es puro.
public struct LaunchContext: Sendable {
    public var session: Session
    public var project: Project
    public var branch: Branch
    public var directory: String
    public var path: String
    public var inheritedEnvironment: [String: String]
    public var paths: HivePaths
    public var claudeInline: Bool
    public var historyHint: Bool
    public var newAgentId: String
    public var claudeConversationExists: Bool
    /// Grok ya guardó la sesión con ese ID (se retoma con --resume en lugar de crearla).
    public var grokConversationExists: Bool
    /// Thread de Codex o sesión de Gemini encontrados en disco (si no se conocían).
    public var discoveredAgentId: String?
    public var mcpFile: URL?
    public var mcpServers: [MCPServer]
    public var geminiSettingsPath: String?
    public var codexExistingNotify: [String]?
    /// Claude arranca con el statusLine de Hive (uso de contexto y límites). Lo llena quien arma el contexto
    /// según el ajuste `showClaudeUsage`; por defecto, apagado (los ajustes de siempre, sin statusLine).
    public var claudeUsage: Bool
    /// El statusLine que ya tenías configurado en Claude: el de Hive lo sigue llamando.
    public var claudeUserStatusLine: String?
    public var handoffContext: String?
    /// Línea de tiempo leída fuera del hilo principal, para recuperar el scroll al lanzar.
    public var historyEntries: [HistoryEntry]

    public init(session: Session, project: Project, branch: Branch, directory: String, path: String,
                inheritedEnvironment: [String: String], paths: HivePaths, claudeInline: Bool = true, historyHint: Bool = true,
                newAgentId: String = UUID().uuidString.lowercased(), claudeConversationExists: Bool = false,
                grokConversationExists: Bool = false, discoveredAgentId: String? = nil, mcpFile: URL? = nil, mcpServers: [MCPServer] = [],
                geminiSettingsPath: String? = nil, codexExistingNotify: [String]? = nil,
                claudeUsage: Bool = false, claudeUserStatusLine: String? = nil, handoffContext: String? = nil,
                historyEntries: [HistoryEntry] = []) {
        self.session = session
        self.project = project
        self.branch = branch
        self.directory = directory
        self.path = path
        self.inheritedEnvironment = inheritedEnvironment
        self.paths = paths
        self.claudeInline = claudeInline
        self.historyHint = historyHint
        self.newAgentId = newAgentId
        self.claudeConversationExists = claudeConversationExists
        self.grokConversationExists = grokConversationExists
        self.discoveredAgentId = discoveredAgentId
        self.mcpFile = mcpFile
        self.mcpServers = mcpServers
        self.geminiSettingsPath = geminiSettingsPath
        self.codexExistingNotify = codexExistingNotify
        self.claudeUsage = claudeUsage
        self.claudeUserStatusLine = claudeUserStatusLine
        self.handoffContext = handoffContext
        self.historyEntries = historyEntries
    }
}

public enum LaunchPlanner {
    public static func plan(_ ctx: LaunchContext) -> LaunchPlan {
        var env = SessionEnvironment.base(inherited: ctx.inheritedEnvironment, directory: ctx.directory, path: ctx.path)
        env["HIVE_SESSION_ID"] = ctx.session.id.uuidString
        env["HIVE_EVENTS_DIR"] = ctx.paths.eventsDir.path
        env["HIVE_EVENT_BIN"] = ctx.paths.eventBin.path
        env["HIVE_PROJECT"] = ctx.project.name
        env["HIVE_BRANCH"] = ctx.branch.name
        if ctx.session.kind.reportsConversation {
            env["HIVE_HISTORY_FILE"] = HistoryStore(directory: ctx.paths.historyDir).markdownURL(ctx.session.id).path
        }

        let hint = ctx.handoffContext ?? (ctx.historyHint && ctx.session.kind.reportsConversation
            ? HistoryStore.agentHint(markdown: HistoryStore(directory: ctx.paths.historyDir).markdownURL(ctx.session.id))
            : nil)

        switch ctx.session.kind {
        case .shell:
            return LaunchPlan(binary: nil, args: ["-l"], environment: env, agentSessionId: nil)

        case .claude:
            let agentId = ctx.session.agentSessionId ?? ctx.newAgentId
            var args = ctx.claudeConversationExists
                ? ["--resume", agentId]
                : ["--session-id", agentId, "--name", ctx.session.name]
            args += ["--settings", (ctx.claudeUsage ? ctx.paths.claudeSettingsWithUsage : ctx.paths.claudeSettings).path]
            if ctx.claudeUsage, let statusLine = ctx.claudeUserStatusLine?.trimmingCharacters(in: .whitespacesAndNewlines), !statusLine.isEmpty {
                env["HIVE_USER_STATUSLINE"] = statusLine
            }
            if let hint { args += ["--append-system-prompt", hint] }
            // Claude lee el .mcp.json de su carpeta; en un worktree que no lo tiene, le pasamos el del repo.
            if let mcpFile = ctx.mcpFile, !samePath(mcpFile.deletingLastPathComponent().path, ctx.directory) {
                args += ["--mcp-config", mcpFile.path]
            }
            // En la terminal normal la charla queda en el scroll, también después de /clear.
            let restored = ConversationScrollback.previousEntries(ctx.historyEntries, resuming: ctx.claudeConversationExists)
            if ctx.claudeInline || ctx.session.handoffFrom != nil || !restored.isEmpty {
                env["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] = "1"
            }
            return LaunchPlan(binary: "claude", args: args, environment: env, agentSessionId: agentId,
                              restoredHistory: restored)

        case .codex:
            let thread = ctx.session.agentSessionId ?? ctx.discoveredAgentId
            var extra = MCPConfig.codexOverrides(ctx.mcpServers)
            if let hint { extra += ["-c", "developer_instructions=" + TOML.string(hint)] }
            let notify = CodexNotify.override(eventBin: ctx.paths.eventBin.path, existing: ctx.codexExistingNotify)
            var args: [String] = thread == nil ? [] : ["resume"]
            args += ["-c", notify] + extra
            // Igual que Claude: sin pantalla alternativa, la charla queda en el scroll para leerla y copiarla.
            let restored = ConversationScrollback.previousEntries(ctx.historyEntries, resuming: thread != nil)
            if ctx.claudeInline || ctx.session.handoffFrom != nil || !restored.isEmpty {
                args += ["-c", #"tui.alternate_screen="never""#]
            }
            if let thread { args.append(thread) }
            return LaunchPlan(binary: "codex", args: args, environment: env, agentSessionId: thread,
                              restoredHistory: restored)

        case .gemini:
            // El chat que ya era de esta sesión le gana a cualquiera que aparezca en la carpeta.
            let sessionId = ctx.session.agentSessionId ?? ctx.discoveredAgentId
            if let settings = ctx.geminiSettingsPath { env["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = settings }
            return LaunchPlan(binary: "gemini", args: sessionId.map { ["--resume", $0] } ?? [], environment: env, agentSessionId: sessionId)

        case .grok:
            // Como Claude: le damos el ID al crearla y la retomamos con ese mismo ID. Los avisos llegan
            // por los hooks personales que instala `AgentStorage.installGrokHooks`.
            let agentId = ctx.session.agentSessionId ?? ctx.newAgentId
            var args = ctx.grokConversationExists ? ["--resume", agentId] : ["--session-id", agentId]
            // Sin pantalla alternativa, la charla queda en el scroll para leerla y copiarla.
            if ctx.claudeInline { args.append("--no-alt-screen") }
            return LaunchPlan(binary: "grok", args: args, environment: env, agentSessionId: agentId)
        }
    }
}

/// Entorno para procesos lanzados desde Hive (sesiones y comandos).
public enum SessionEnvironment {
    /// Prefijos de variables heredadas que confundirían a los agentes (por ejemplo, si Hive se lanzó
    /// desde otra terminal o desde dentro de otro agente).
    public static let droppedPrefixes = ["CLAUDECODE", "CLAUDE_CODE_", "CODEX_SANDBOX", "CODEX_ESCALATE", "CODEX_THREAD",
                                         "TERM_PROGRAM", "TERM_SESSION_ID", "ITERM_", "WARP_", "VSCODE_", "__CFBundle", "HIVE_"]
    public static let droppedNames: Set<String> = ["SHLVL", "OLDPWD", "_"]

    public static func base(inherited: [String: String], directory: String, path: String) -> [String: String] {
        var env = inherited.filter { key, _ in
            !droppedPrefixes.contains(where: { key.hasPrefix($0) }) && !droppedNames.contains(key)
        }
        env["PATH"] = path
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Hive"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["PWD"] = directory
        addAndroidSDK(&env)
        return env
    }

    /// Android Studio instala el SDK en ~/Library/Android/sdk pero no define ANDROID_HOME ni pone `adb`
    /// en el PATH: sin esto, Gradle y adb no andan desde una sesión.
    static func addAndroidSDK(_ env: inout [String: String]) {
        guard env["ANDROID_HOME"] == nil, let home = env["HOME"], !home.isEmpty else { return }
        let sdk = (home as NSString).appendingPathComponent("Library/Android/sdk")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sdk, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        env["ANDROID_HOME"] = sdk
        let tools = (sdk as NSString).appendingPathComponent("platform-tools")
        let path = env["PATH"] ?? ""
        if !path.split(separator: ":").contains(Substring(tools)) {
            env["PATH"] = path.isEmpty ? tools : path + ":" + tools
        }
    }
}

/// `notify=[hive-event, "codex", <notify original...>]`: Codex nos avisa al terminar cada turno
/// y el script reenvía el aviso al notify que ya tuvieras configurado.
public enum CodexNotify {
    public static func override(eventBin: String, existing: [String]?) -> String {
        let command = [eventBin, "codex"] + (existing ?? [])
        return "notify=[" + command.map(TOML.string).joined(separator: ", ") + "]"
    }

    /// El `notify = [...]` de nivel superior de un config.toml (con comillas simples o dobles,
    /// en una o varias líneas). Si no está o no se puede leer, nil.
    public static func existing(inConfig text: String) -> [String]? {
        if case .found(let command) = TOML.topLevelStringArray("notify", in: text) { return command }
        return nil
    }
}

public enum TOML {
    /// Texto entre comillas con los escapes de TOML.
    public static func string(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }

    /// Clave simple de TOML (letras, números, `_` y `-`).
    public static func bareKey(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }
}
