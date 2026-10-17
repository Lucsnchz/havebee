import Foundation

/// Recupera la asociación de Hive a una conversación nativa, sin elegir chats ajenos del mismo repo.
public enum CodexSessionRecovery {
    public static func resolve(_ session: Session, directory: String, agents: AgentStorage,
                               history: HistoryStore, excluding claimedIds: Set<String>) -> Session {
        guard session.kind == .codex, let saved = session.agentSessionId else { return session }
        if agents.codexRolloutURL(saved) != nil, !agents.isCodexSubagentThread(saved) { return session }
        // Solo las conversaciones registradas en ESTE chat, posteriores a su último cambio de IA.
        let handoff = history.load(session.id).last {
            $0.role == .marker && $0.text.hasPrefix(AgentHandoff.markerPrefix)
        }?.date ?? .distantPast
        var recovered = session
        recovered.agentSessionId = history.transcriptSegments(session.id)
            .filter { $0.agent == .codex && $0.since >= handoff && !claimedIds.contains($0.conversationId) }
            .sorted { $0.since > $1.since }
            .first { agents.isCodexConversation($0.conversationId, in: directory) }?.conversationId
        return recovered
    }
}
