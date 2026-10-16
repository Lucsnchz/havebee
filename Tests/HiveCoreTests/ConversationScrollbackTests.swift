import Foundation
import Testing
@testable import HiveCore

@Suite("Historial visible de la conversación")
struct ConversationScrollbackTests {
    private func entry(_ role: HistoryEntry.Role, _ text: String, _ agent: SessionKind = .claude) -> HistoryEntry {
        HistoryEntry(date: .reference, role: role, text: text, agent: agent)
    }

    @Test("Un agente nuevo recibe todo el scroll; un resume solo repone lo que el agente no conoce")
    func resumeBoundary() {
        let entries = [entry(.user, "Primer pedido"), entry(.assistant, "Respuesta de Claude"),
                       entry(.marker, AgentHandoff.markerPrefix + "Claude Code → Codex"),
                       entry(.user, "Seguí"), entry(.assistant, "Respuesta de Codex", .codex),
                       entry(.marker, "/compact"), entry(.marker, "⚠︎ Se cortó: rate_limit")]
        let fresh = ConversationScrollback.text(entries, agent: .codex, resuming: false)
        #expect(fresh.contains("Vos: Primer pedido") && fresh.contains("Claude Code: Respuesta de Claude"))
        #expect(fresh.contains("Codex: Respuesta de Codex"))
        let resumed = ConversationScrollback.text(entries, agent: .codex, resuming: true)
        #expect(resumed.contains("Primer pedido") && resumed.contains("Cambio de IA"))
        #expect(!resumed.contains("Respuesta de Codex") && !resumed.contains("/compact"))
        #expect(ConversationScrollback.text(Array(entries.prefix(2)), agent: .claude, resuming: true).isEmpty)
    }

    @Test("Al retomar después de /clear también restaura los agentes anteriores", arguments: ["/clear", "Nueva conversación"])
    func clearBoundary(_ marker: String) {
        let entries = [entry(.assistant, "Antes del cambio"),
                       entry(.marker, AgentHandoff.markerPrefix + "Claude Code → Codex"),
                       entry(.assistant, "Antes de limpiar", .codex), entry(.marker, marker),
                       entry(.assistant, "Conversación actual", .codex)]
        let text = ConversationScrollback.text(entries, agent: .codex, resuming: true)
        #expect(text.contains("Antes del cambio") && text.contains("Antes de limpiar") && text.contains(marker))
        #expect(!text.contains("Conversación actual"))
    }

    @Test("El lanzamiento mantiene el scroll accesible y comunica la ruta del historial", arguments: [SessionKind.claude, .codex])
    func launch(_ agent: SessionKind) {
        let paths = HivePaths(root: URL(fileURLWithPath: "/datos con espacios/Hive"))
        var ctx = LaunchContext(session: Session(name: "Compartida", kind: agent),
                                project: Project(name: "App", path: "/app"), branch: Branch(name: "main", mode: .main),
                                directory: "/app", path: "/bin", inheritedEnvironment: ["HIVE_HISTORY_FILE": "/otra.md"],
                                paths: paths, claudeInline: false)
        ctx.historyEntries = [entry(.assistant, "Mensaje anterior")]
        let plan = LaunchPlanner.plan(ctx)
        #expect(plan.restoredHistory.contains { $0.text == "Mensaje anterior" && $0.role == .assistant })
        #expect(plan.environment["HIVE_HISTORY_FILE"] == HistoryStore(directory: paths.historyDir).markdownURL(ctx.session.id).path)
        #expect(plan.args.contains { $0.contains("revisá el historial") && $0.contains("HIVE_HISTORY_FILE") })
        if agent == .claude {
            #expect(plan.environment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] == "1")
        } else {
            #expect(plan.args.contains(#"tui.alternate_screen="never""#))
        }
    }
}
