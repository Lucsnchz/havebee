import Foundation
import Testing
@testable import HiveCore

@Suite("Confirmar antes de cortar una sesión")
struct InterruptRuleTests {
    @Test("Un agente pregunta si trabaja o espera permiso; nunca si está listo, te toca, duerme o terminó")
    func agentStates() {
        let asks: [SessionStatus] = [.working, .attention]
        let silent: [SessionStatus] = [.idle, .waiting, .dormant, .exited(0), .exited(nil), .exited(1)]
        for status in asks {
            #expect(InterruptRule.needsConfirmation(status: status, isAgent: true, foregroundJob: nil), "\(status)")
        }
        for status in silent {
            #expect(!InterruptRule.needsConfirmation(status: status, isAgent: true, foregroundJob: nil), "\(status)")
        }
    }

    @Test("Una Terminal pregunta solo con un proceso en primer plano (no con el shell esperando en el prompt)")
    func terminalJobs() {
        #expect(!InterruptRule.needsConfirmation(status: .idle, isAgent: false, foregroundJob: nil))
        #expect(InterruptRule.needsConfirmation(status: .idle, isAgent: false, foregroundJob: "node"))
        // Sin nombre (no se pudo leer) también cuenta.
        #expect(InterruptRule.needsConfirmation(status: .idle, isAgent: false, foregroundJob: ""))
        // Terminada o dormida no hay nada que cortar.
        #expect(!InterruptRule.needsConfirmation(status: .exited(0), isAgent: false, foregroundJob: "node"))
        #expect(!InterruptRule.needsConfirmation(status: .dormant, isAgent: false, foregroundJob: "node"))
    }

    @Test("Los mismos estados piden confirmación para archivar, reiniciar y detener")
    func sameRuleForEveryAction() {
        let cases: [(SessionStatus, Bool, String?)] = [
            (.working, true, nil), (.attention, true, nil), (.idle, true, nil), (.waiting, true, nil),
            (.idle, false, nil), (.idle, false, "npm"), (.exited(nil), false, "npm"),
        ]
        for (status, isAgent, job) in cases {
            let expected = InterruptRule.needsConfirmation(status: status, isAgent: isAgent, foregroundJob: job)
            for action in SessionInterruption.allCases {
                let confirmation = InterruptRule.confirmation(for: action, sessionName: "X", isAgent: isAgent, status: status, foregroundJob: job)
                #expect((confirmation != nil) == expected, "\(action) \(status) \(isAgent) \(job ?? "-")")
            }
        }
    }

    @Test("Textos de un agente trabajando: qué se corta, que la conversación queda y cómo frenar solo el turno")
    func agentWorkingTexts() throws {
        let archive = try #require(InterruptRule.confirmation(for: .archive, sessionName: "Claude 2", isAgent: true, status: .working, foregroundJob: nil))
        #expect(archive.title == "«Claude 2» está trabajando")
        #expect(archive.message == "Si la archivás, se corta lo que está haciendo. La conversación queda guardada y la podés restaurar.")
        #expect(archive.actionTitle == "Archivar igual")

        let restart = try #require(InterruptRule.confirmation(for: .restart, sessionName: "Claude 2", isAgent: true, status: .working, foregroundJob: nil))
        #expect(restart.actionTitle == "Reiniciar igual")
        #expect(restart.message == "Si la reiniciás, se corta lo que está haciendo. La conversación queda guardada y se retoma al arrancar. Para frenar solo este turno, apretá Esc en la terminal.")

        let stop = try #require(InterruptRule.confirmation(for: .stop, sessionName: "Codex 1", isAgent: true, status: .working, foregroundJob: nil))
        #expect(stop.title == "«Codex 1» está trabajando")
        #expect(stop.actionTitle == "Detener igual")
        #expect(stop.message.hasPrefix("Si la detenés, se corta lo que está haciendo. La conversación queda guardada y la podés reanudar."))
        #expect(stop.message.hasSuffix("apretá Esc en la terminal."))
    }

    @Test("Esperando permiso: lo dice en el título y explica que está a mitad de algo")
    func agentAttentionTexts() throws {
        let archive = try #require(InterruptRule.confirmation(for: .archive, sessionName: "Claude 1", isAgent: true, status: .attention, foregroundJob: nil))
        #expect(archive.title == "«Claude 1» necesita permiso")
        #expect(archive.message.hasPrefix("Está esperando tu permiso a mitad de lo que estaba haciendo. Si la archivás, se corta."))
        #expect(!archive.message.contains("Esc"))
    }

    @Test("Una Terminal nombra el proceso que se corta (o dice «un proceso» si no se sabe)")
    func terminalTexts() throws {
        let archive = try #require(InterruptRule.confirmation(for: .archive, sessionName: "Terminal 1", isAgent: false, status: .idle, foregroundJob: "node"))
        #expect(archive.title == "«node» está corriendo en «Terminal 1»")
        #expect(archive.message == "Si la archivás, se corta. «Deshacer» devuelve la pestaña, pero no el proceso.")
        #expect(archive.actionTitle == "Archivar igual")

        let stop = try #require(InterruptRule.confirmation(for: .stop, sessionName: "Terminal 1", isAgent: false, status: .idle, foregroundJob: ""))
        #expect(stop.title == "Hay un proceso corriendo en «Terminal 1»")
        #expect(stop.actionTitle == "Detener igual")

        let restart = try #require(InterruptRule.confirmation(for: .restart, sessionName: "Terminal 1", isAgent: false, status: .idle, foregroundJob: "sleep"))
        #expect(restart.message == "Si reiniciás la terminal, se corta.")
        #expect(restart.actionTitle == "Reiniciar igual")
    }
}
