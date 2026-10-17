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
    /// Claude arranca con el statusLine de Hive (uso de contexto y límites): ajuste `showClaudeUsage`.
    public var claudeUsage: Bool
    /// IDs de conversación que ya usan otras sesiones del mismo tipo (no se los roba).
    public var claimedAgentIds: Set<String>
    public var now: Date

    public init(session: Session, project: Project, branch: Branch, directory: String, path: String,
                inheritedEnvironment: [String: String], paths: HivePaths, agents: AgentStorage,
                claudeInline: Bool = true, historyHint: Bool = true, claudeUsage: Bool = false,
                claimedAgentIds: Set<String> = [], now: Date = Date()) {
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
        self.claudeUsage = claudeUsage
        self.claimedAgentIds = claimedAgentIds
        self.now = now
    }

    /// Dónde está la sesión, para el encabezado del historial («tienda › main»).
    public var place: String { project.isScratch ? project.name : "\(project.name) › \(branch.name)" }

    public func build() -> LaunchContext {
        let history = HistoryStore(directory: paths.historyDir)
        if session.kind.reportsConversation {
            _ = try? history.repairCodexHistory(session: session, place: place)
        }
        let resolved = CodexSessionRecovery.resolve(session, directory: directory, agents: agents,
                                                    history: history, excluding: claimedAgentIds)
        let replacedMissingCodex = session.kind == .codex && resolved.agentSessionId != session.agentSessionId
        if session.kind.reportsConversation {
            // El archivo existe desde el arranque, para que la IA lo encuentre.
            HistoryStore(directory: paths.historyDir).ensureMarkdown(session: session, place: place)
        }
        let mcp = MCPConfig.forWorktree(file: MCPConfig.effectiveFile(directory: directory, projectPath: project.path),
                                      root: project.path, directory: directory,
                                      output: paths.root.appendingPathComponent("mcp/\(session.id.uuidString).json"),
                                      herdExecutable: branch.herdSite == nil ? nil : HerdSites.defaultRoot(
                                        home: URL(fileURLWithPath: inheritedEnvironment["HOME"] ?? NSHomeDirectory()))
                                        .appendingPathComponent("bin/herd").path)
        let mcpFile = mcp.file
        let mcpServers = mcp.servers
        var discovered: String?
        // Solo si ya se lanzó antes y no sabemos su conversación: la buscamos entre las que se crearon después.
        if let since = session.lastLaunchedAt, resolved.agentSessionId == nil, !replacedMissingCodex {
            switch session.kind {
            case .codex:
                discovered = agents.discoverCodexThread(cwd: directory, since: since, excluding: claimedAgentIds, now: now)
            case .gemini:
                discovered = agents.discoverGeminiSession(cwd: directory, since: since, excluding: claimedAgentIds)
            default:
                break
            }
        }
        // Con el uso de Hive, el statusLine que ya tenías en Claude se sigue mostrando (Hive lo llama).
        let userStatusLine = session.kind == .claude && claudeUsage ? agents.claudeUserStatusLine(directory: directory) : nil
        // Los hooks de Grok van en su carpeta personal: se revisan en cada arranque por si los borraste.
        if session.kind == .grok { agents.installGrokHooks() }
        let geminiSettings = session.kind == .gemini
            ? MCPConfig.writeGeminiSettings(mcpServers, to: paths.geminiDir.appendingPathComponent("\(session.id.uuidString).json"))
            : nil
        let entries = session.kind.reportsConversation ? history.fullTimeline(session.id, agent: session.kind) : []
        var handoffContext = session.handoffFrom.map {
            AgentHandoff.instructions(from: $0, markdown: history.markdownURL(session.id),
                                      entries: entries)
        }
        if replacedMissingCodex && resolved.agentSessionId == nil {
            handoffContext = AgentHandoff.recoveryInstructions(markdown: history.markdownURL(session.id), entries: entries)
        }
        return LaunchContext(
            session: resolved, project: project, branch: branch, directory: directory, path: path,
            inheritedEnvironment: inheritedEnvironment, paths: paths,
            claudeInline: claudeInline, historyHint: historyHint,
            claudeConversationExists: session.kind == .claude && session.agentSessionId.map(agents.claudeConversationExists) == true,
            grokConversationExists: session.kind == .grok && session.agentSessionId.map(agents.grokSessionExists) == true,
            discoveredAgentId: discovered, mcpFile: mcpFile, mcpServers: mcpServers, geminiSettingsPath: geminiSettings,
            codexExistingNotify: session.kind == .codex ? agents.codexExistingNotify() : nil,
            claudeUsage: claudeUsage, claudeUserStatusLine: userStatusLine, handoffContext: handoffContext,
            historyEntries: entries, resumeInterruptedWork: canContinueInterruptedWork(agentId: resolved.agentSessionId ?? discovered))
    }

    private func canContinueInterruptedWork(agentId: String?) -> Bool {
        guard !session.isArchived, let pending = session.pendingWork, let agentId else { return false }
        let transcript: URL?
        switch session.kind {
        case .claude: transcript = agents.claudeTranscriptURL(agentId)
        case .codex: transcript = agents.codexRolloutURL(agentId)
        case .grok: return agents.grokSessionExists(agentId)
        // Sin hooks de fin o permiso, la actividad de la terminal sola no alcanza para continuar sola.
        case .gemini, .shell: return false
        }
        guard let transcript else { return false }
        return InterruptedWork.allowsContinuation(transcript: transcript, agent: session.kind, pending: pending)
    }
}
