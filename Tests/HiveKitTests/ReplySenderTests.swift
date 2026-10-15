import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Responder desde el aviso", .serialized)
struct ReplySenderTests {
    /// Una sesión de Claude en «Terminales» (su carpeta existe y no hace falta git).
    @MainActor
    final class ReplyFixture {
        let world = TestWorld()
        let store: AppStore
        let session: Session
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hive-reply-\(UUID().uuidString)"))

        init() throws {
            store = world.makeStore()
            let branch = try #require(store.scratchProject?.branches.first)
            store.requestNewSession(branchId: branch.id, kind: .claude)
            session = try #require(store.scratchProject?.branches.first?.sessions.last)
            store.select(nil)
        }

        deinit { pasteboard.releaseGlobally() }

        /// Arranca la sesión (con procesos falsos) y anota todo lo que se le escribe.
        func launch() throws -> (HiveTerminalView, () -> [UInt8]) {
            store.activate(session.id)
            let terminal = try #require(store.runtimes[session.id]?.terminal)
            var sent: [UInt8] = []
            let original = terminal.onUserInput
            terminal.onUserInput = { data in
                sent += data
                original?(data)
            }
            return (terminal, { sent })
        }
    }

    @Test("Bytes con y sin pegado entre corchetes")
    func payload() {
        let text = "seguí con los tests\ny avisame"
        #expect(ReplySender.payload(text, bracketed: false) == Array(text.utf8))
        #expect(ReplySender.payload(text, bracketed: true)
            == Array("\u{1B}[200~".utf8) + Array(text.utf8) + Array("\u{1B}[201~".utf8))
        #expect(!ReplySender.payload("hola", bracketed: true).contains(13))
    }

    @Test("Con la sesión corriendo escribe el texto, después Enter, y pasa a «Trabajando»")
    func typesIntoRunningSession() async throws {
        let f = try ReplyFixture()
        let (_, sent) = try f.launch()
        #expect(f.store.runtimes[f.session.id]?.status == .idle)
        let outcome = ReplySender.send("dale", sessionId: f.session.id, store: f.store, pasteboard: f.pasteboard, activateApp: {})
        #expect(outcome == .typed)
        #expect(sent() == Array("dale".utf8)) // el Enter todavía no
        #expect(await waitUntil { sent().last == 13 })
        #expect(sent() == Array("dale".utf8) + [13])
        #expect(f.store.runtimes[f.session.id]?.status == .working)
        #expect(f.store.alert == nil)
    }

    @Test("Si el programa pidió pegado entre corchetes, el texto va entre corchetes")
    func bracketedWhenEnabled() async throws {
        let f = try ReplyFixture()
        let (terminal, sent) = try f.launch()
        terminal.feed(text: "\u{1B}[?2004h")
        #expect(await waitUntil { terminal.terminalStateSnapshot().bracketedPasteMode })
        ReplySender.send("sí", sessionId: f.session.id, store: f.store, pasteboard: f.pasteboard, activateApp: {})
        #expect(await waitUntil { sent().last == 13 })
        #expect(sent() == ReplySender.pasteStart + Array("sí".utf8) + ReplySender.pasteEnd + [13])
    }

    @Test("Sin terminal corriendo abre la sesión y deja el texto en el portapapeles")
    func copiesWhenNotRunning() throws {
        let f = try ReplyFixture()
        var activated = false
        let outcome = ReplySender.send("probá de nuevo", sessionId: f.session.id, store: f.store, pasteboard: f.pasteboard,
                                       activateApp: { activated = true })
        #expect(outcome == .copied)
        #expect(activated)
        #expect(f.pasteboard.string(forType: .string) == "probá de nuevo")
        #expect(f.store.selection == .session(f.session.id))
        #expect(f.store.alert?.title == "Copié tu respuesta")
        #expect(f.store.runtimes[f.session.id]?.status == .dormant)
    }

    @Test("Una sesión que ya no existe no hace nada")
    func missingSession() throws {
        let f = try ReplyFixture()
        #expect(ReplySender.send("x", sessionId: UUID(), store: f.store, pasteboard: f.pasteboard, activateApp: {}) == .missing)
        #expect(f.pasteboard.string(forType: .string) == nil)
        #expect(f.store.alert == nil)
    }
}
