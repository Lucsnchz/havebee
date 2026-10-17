import Foundation
import Testing
@testable import HiveCore

private struct CodexRecoveryFixture {
    let root = TempDir("codex-recovery")
    let session = Session(name: "Permisos", kind: .codex, agentSessionId: "temporary-summary", lastLaunchedAt: .reference)
    var paths: HivePaths { HivePaths(root: root.url.appendingPathComponent("Hive")) }
    var history: HistoryStore { HistoryStore(directory: paths.historyDir) }
    var directory: String { root.url.appendingPathComponent("repo").path }
    var agents: AgentStorage {
        AgentStorage(claudeConfigDir: root.url.appendingPathComponent("claude"),
                     codexHome: root.url.appendingPathComponent("codex"), geminiHome: root.url.appendingPathComponent("gemini"))
    }

    func record(_ id: String, offset: Double = 0, cwd: String? = nil, source: String = "cli", registered: Bool = true) throws {
        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": id, "cwd": cwd ?? directory, "source": source]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: meta), as: UTF8.self) + "\n"
        let url = root.write("codex/sessions/2026/10/16/rollout-2026-10-16-\(id).jsonl", text)
        if registered {
            history.recordTranscript(sessionId: session.id, agent: .codex, conversationId: id, path: url.path,
                                     now: Date.reference.addingTimeInterval(offset))
        }
    }

    func builder(session override: Session? = nil, excluding: Set<String> = []) -> LaunchContextBuilder {
        LaunchContextBuilder(session: override ?? session, project: Project(name: "App", path: directory),
                             branch: Branch(name: "main", mode: .main), directory: directory, path: "/bin",
                             inheritedEnvironment: [:], paths: paths, agents: agents, historyHint: false,
                             claimedAgentIds: excluding, now: Date.reference.addingTimeInterval(100))
    }
}

@Suite("Codex: recuperar el ID del chat correcto")
struct CodexSessionRecoveryTests {
    @Test("Recupera el último ID registrado en ese chat, sin tomar otro del mismo repo")
    func registeredConversation() throws {
        let f = CodexRecoveryFixture()
        try f.record("older", offset: -20)
        try f.record("original")
        try f.record("other-chat", offset: 10, registered: false)
        let plan = LaunchPlanner.plan(f.builder().build())
        #expect(plan.agentSessionId == "original")
        #expect(plan.args.first == "resume" && plan.args.last == "original")
        #expect(!plan.args.contains("temporary-summary"))
    }

    @Test("Un ID válido ya guardado se respeta")
    func validSession() throws {
        let f = CodexRecoveryFixture()
        try f.record("original")
        var session = f.session
        session.agentSessionId = "original"
        #expect(f.builder(session: session).build().session.agentSessionId == "original")
    }

    @Test("No recupera conversaciones ajenas, subagentes ni de antes del último cambio de IA", arguments: [
        "claimed", "other-directory", "subagent", "vscode", "old-handoff"
    ])
    func excludesOtherConversations(reason: String) throws {
        let f = CodexRecoveryFixture()
        try f.record("original", cwd: reason == "other-directory" ? "/another/repo" : nil,
                     source: reason == "subagent" ? "subagent" : (reason == "vscode" ? "vscode" : "cli"))
        if reason == "old-handoff" {
            f.history.append(HistoryEntry(date: Date.reference.addingTimeInterval(1), role: .marker,
                                          text: "Cambio de IA: Claude Code → Codex", agent: .codex),
                             sessionId: f.session.id, agentName: "Codex")
        }
        let ctx = f.builder(excluding: reason == "claimed" ? ["original"] : []).build()
        #expect(ctx.session.agentSessionId == nil)
        #expect(!LaunchPlanner.plan(ctx).args.contains("resume"))
    }

    @Test("Sin conversación nativa conserva el contexto y no manda una tarea automática")
    func missingAllNativeHistory() {
        let f = CodexRecoveryFixture()
        f.history.ensureMarkdown(session: f.session, place: "App")
        f.history.append(HistoryEntry(date: .reference, role: .assistant, text: "Permisos comprobados; falta el commit.", agent: .codex),
                         sessionId: f.session.id, agentName: "Codex")
        var session = f.session
        session.pendingWork = PendingAgentWork(launchId: UUID(), since: .reference)
        let plan = LaunchPlanner.plan(f.builder(session: session).build())
        #expect(plan.agentSessionId == nil)
        #expect(!plan.args.contains("resume") && !plan.continuesInterruptedWork)
        #expect(!plan.args.contains(InterruptedWork.prompt))
        #expect(plan.restoredHistory.contains { $0.text.contains("Permisos comprobados") })
        #expect(plan.args.contains { $0.contains("developer_instructions=") && $0.contains("Permisos comprobados") })
    }
}
