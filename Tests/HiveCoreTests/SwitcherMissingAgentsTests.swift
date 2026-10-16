import Foundation
import Testing
@testable import HiveCore

@Suite("Buscador: agentes no instalados")
struct SwitcherMissingAgentsTests {
    let project = Project(name: "ecommerce", path: "/repos/ecommerce", branches: [Branch(name: "main", mode: .main)])

    @Test("La acción de un agente no instalado lo dice y muestra el comando para instalarlo")
    func missingAgentSubtitle() throws {
        let actions = SwitcherIndex.actions(projects: [project], missingAgents: [.gemini])
        let gemini = try #require(actions.first { $0.target == .action(.newSession(branch: project.branches[0].id, kind: .gemini)) })
        #expect(gemini.subtitle == "No instalado · \(SessionKind.gemini.installHint)")
        let claude = try #require(actions.first { $0.target == .action(.newSession(branch: project.branches[0].id, kind: .claude)) })
        #expect(claude.subtitle == "Agente nuevo en esa carpeta")
        let shell = try #require(actions.first { $0.target == .action(.newSession(branch: project.branches[0].id, kind: .shell)) })
        #expect(shell.subtitle == "Tu shell en esa carpeta")
    }

    @Test("La búsqueda con «>» pasa los agentes no instalados a las acciones")
    func searchPassesMissingAgents() throws {
        let results = SwitcherIndex.search(">nueva gemini", in: [project], missingAgents: [.gemini])
        let first = try #require(results.first)
        #expect(first.title.hasPrefix("Nueva sesión de Gemini"))
        #expect(first.subtitle.hasPrefix("No instalado"))
        // Sin agentes faltantes, como siempre.
        #expect(SwitcherIndex.search(">nueva gemini", in: [project]).first?.subtitle == "Agente nuevo en esa carpeta")
    }
}
