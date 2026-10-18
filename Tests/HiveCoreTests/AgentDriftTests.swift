import Foundation
import Testing
@testable import HiveCore

/// Una sesión que arrancó en una rama y cuyo agente después se pasó a otra: a otro worktree, o con un
/// checkout en la carpeta principal.
@Suite("Dónde trabaja el agente de una sesión")
struct AgentDriftTests {
    static let main = Branch(name: "main", mode: .main)
    static let wsp = Branch(name: "mensajes-wsp", mode: .worktree, worktreePath: "/code/tienda-wsp")
    static let claude = Branch(name: "claude/arreglo", mode: .worktree, worktreePath: "/code/tienda/.claude/worktrees/arreglo")
    static let project = Project(name: "tienda", path: "/code/tienda", branches: [main, wsp, claude])

    @Test("En su carpeta, o en una subcarpeta, sigue en su rama")
    func stays() {
        for cwd in [nil, "/code/tienda", "/code/tienda/", "/code/tienda/app/Models"] as [String?] {
            #expect(AgentDrift.of(Self.main, in: Self.project, cwd: cwd, head: "main") == nil)
        }
        #expect(AgentDrift.of(Self.wsp, in: Self.project, cwd: "/code/tienda-wsp/resources", head: "main") == nil)
    }

    @Test("Arrancó en main y se pasó a otro worktree")
    func otherWorktree() {
        #expect(AgentDrift.of(Self.main, in: Self.project, cwd: "/code/tienda-wsp/app", head: "main")
                == AgentDrift(branchName: "mensajes-wsp", directory: "/code/tienda-wsp"))
        // El de Claude está adentro de la carpeta principal: gana la carpeta más específica.
        #expect(AgentDrift.of(Self.main, in: Self.project, cwd: "/code/tienda/.claude/worktrees/arreglo/src", head: "main")
                == AgentDrift(branchName: "claude/arreglo", directory: "/code/tienda/.claude/worktrees/arreglo"))
        // Una carpeta que solo empieza igual no es la del worktree.
        #expect(AgentDrift.of(Self.main, in: Self.project, cwd: "/code/tienda-wsp2", head: "main") == nil)
    }

    @Test("Checkout de otra rama en la carpeta principal, o vuelta a ella desde un worktree")
    func mainFolder() {
        #expect(AgentDrift.of(Self.main, in: Self.project, cwd: nil, head: "arreglo-pagos")
                == AgentDrift(branchName: "arreglo-pagos", directory: "/code/tienda"))
        #expect(AgentDrift.of(Self.wsp, in: Self.project, cwd: "/code/tienda-wsp/../tienda", head: "main")
                == AgentDrift(branchName: "main", directory: "/code/tienda"))
        // Sin saber todavía la rama de la carpeta principal no se afirma nada.
        #expect(AgentDrift.of(Self.wsp, in: Self.project, cwd: "/code/tienda", head: nil) == nil)
    }

    @Test("/tmp y /private/tmp son la misma carpeta, exista o no la subcarpeta")
    func privatePrefix() {
        let wt = Branch(name: "x", mode: .worktree, worktreePath: "/private/tmp/tienda-x")
        let project = Project(name: "tienda", path: "/tmp/tienda", branches: [Self.main, wt])
        #expect(AgentDrift.of(Self.main, in: project, cwd: "/tmp/tienda-x/no-existe", head: "main")
                == AgentDrift(branchName: "x", directory: "/private/tmp/tienda-x"))
        #expect(AgentDrift.of(Self.main, in: project, cwd: "/private/tmp/tienda/app", head: "main") == nil)
    }

    @Test("Fuera del proyecto o en «Terminales» no cuenta")
    func outside() {
        #expect(AgentDrift.of(Self.main, in: Self.project, cwd: "/code/otro-proyecto", head: "main") == nil)
        let scratch = Project(name: "Terminales", path: "/Users/yo", branches: [Self.main], isScratch: true)
        #expect(AgentDrift.of(Self.main, in: scratch, cwd: "/Users/yo/Herd", head: "otra") == nil)
    }

    @Test("La carpeta sale de cada evento del agente principal, no de sus subagentes")
    func cwdFromEvents() {
        func outcome(_ source: String, _ name: String, _ payload: JSONValue) -> AgentEventOutcome {
            AgentEventInterpreter.interpret(HiveEvent(sessionId: UUID(), source: source, name: name, payload: payload),
                                            status: .working, agentSessionId: "a")
        }
        #expect(outcome("claude", "PostToolUse", ["tool_name": "Bash", "cwd": "/code/tienda-wsp"]).cwd == "/code/tienda-wsp")
        #expect(outcome("claude", "PostToolUse", ["tool_name": "Bash", "cwd": "/code/x", "agent_id": "sub-1"]).cwd == nil)
        #expect(outcome("codex", "notify", ["type": "agent-turn-complete", "thread-id": "a", "cwd": "/code/tienda",
                                            "input-messages": ["Hola"], "last-assistant-message": "Listo"]).cwd == "/code/tienda")
        #expect(outcome("grok", "Stop", ["cwd": "/code/g", "lastAssistantMessage": "Listo"]).cwd == "/code/g")
    }
}
