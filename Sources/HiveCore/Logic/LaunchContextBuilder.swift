import Foundation

/// Arma el `LaunchContext` de una sesión haciendo las búsquedas en disco: el historial en Markdown,
/// los MCP del proyecto, si existe la conversación de Claude, el thread de Codex o el chat de
/// Gemini. Es un valor sin estado de la app: se puede correr fuera del hilo principal.
public struct LaunchContextBuilder: Sendable {
    public var session: Session
    public var project: Project
    public var branch: Branch
    public var directory: String
    public var path: String
    public var inheritedEnvironment: [String: String]
    public var paths: HivePaths
    public var agents: AgentStorage
    public var claudeInline: Bool
    public var historyHint: Bool
    /// IDs de conversación que ya usan otras sesiones del mismo tipo (no se los roba).
    public var claimedAgentIds: Set<String>
    public var now: Date

    public init(session: Session, project: Project, branch: Branch, directory: String, path: String,
                inheritedEnvironment: [String: String], paths: HivePaths, agents: AgentStorage,
                claudeInline: Bool = true, historyHint: Bool = true, claimedAgentIds: Set<String> = [], now: Date = Date()) {
        self.session = session
        self.project = project
        self.branch = branch
        self.directory = directory
        self.path = path
        self.inheritedEnvironment = inheritedEnvironment
        self.paths = paths
        self.agents = agents
        self.claudeInline = claudeInline
        self.historyHint = historyHint
        self.claimedAgentIds = claimedAgentIds
        self.now = now
    }

    /// Dónde está la sesión, para el encabezado del historial («tienda › main»).
    public var place: String { project.isScratch ? project.name : "\(project.name) › \(branch.name)" }

    public func build() -> LaunchContext {
        if session.kind.reportsConversation {
            // El archivo existe desde el arranque, para que la IA lo encuentre.
            HistoryStore(directory: paths.historyDir).ensureMarkdown(session: session, place: place)
        }
        let mcpFile = MCPConfig.effectiveFile(directory: directory, projectPath: project.path)
        let mcpServers = mcpFile.map(MCPConfig.load) ?? []
        var discovered: String?
        // Solo si ya se lanzó antes y no sabemos su conversación: la buscamos entre las que se crearon después.
        if let since = session.lastLaunchedAt, session.agentSessionId == nil {
            switch session.kind {
            case .codex:
                discovered = agents.discoverCodexThread(cwd: directory, since: since, excluding: claimedAgentIds, now: now)
            case .gemini:
                discovered = agents.discoverGeminiSession(cwd: directory, since: since, excluding: claimedAgentIds)
            default:
                break
            }
        }
        let geminiSettings = session.kind == .gemini
            ? MCPConfig.writeGeminiSettings(mcpServers, to: paths.geminiDir.appendingPathComponent("\(session.id.uuidString).json"))
            : nil
        return LaunchContext(
            session: session, project: project, branch: branch, directory: directory, path: path,
            inheritedEnvironment: inheritedEnvironment, paths: paths,
            claudeInline: claudeInline, historyHint: historyHint,
            claudeConversationExists: session.kind == .claude && session.agentSessionId.map(agents.claudeConversationExists) == true,
            discoveredAgentId: discovered, mcpFile: mcpFile, mcpServers: mcpServers, geminiSettingsPath: geminiSettings,
            codexExistingNotify: session.kind == .codex ? agents.codexExistingNotify() : nil)
    }
}
