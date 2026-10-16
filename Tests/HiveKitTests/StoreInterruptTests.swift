import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Un store con una sesión abierta en «Terminales» (procesos falsos: no lanza nada de verdad).
@MainActor
private final class InterruptFixture {
    let world = TestWorld()
    let store: AppStore
    let id: UUID
    let rt: SessionRuntime

    init(_ kind: SessionKind = .claude) throws {
        store = world.makeStore()
        let branch = try #require(store.scratchProject?.branches.first)
        store.requestNewSession(branchId: branch.id, kind: kind)
        id = try #require(store.scratchProject?.branches.first?.sessions.last?.id)
        store.activate(id)
        rt = try #require(store.runtimes[id])
    }

    func permission() {
        store.handle([HiveEvent(sessionId: id, source: "claude", name: "Notification",
                                payload: ["notification_type": "permission_prompt", "message": "Permiso para Bash"])])
    }

    var isArchived: Bool { store.sessionContext(id)?.session.isArchived == true }
}

@MainActor
@Suite("Store: confirmar antes de cortar una sesión")
struct StoreInterruptTests {
    @Test("⌘R con un agente trabajando pregunta antes de reiniciar; si confirmás, reinicia")
    func restartWorking() throws {
        let f = try InterruptFixture()
        f.store.userInput(f.id, [13])
        #expect(f.rt.status == .working)
        let old = try #require(f.rt.terminal)
        f.store.requestRestart(f.id)
        let alert = try #require(f.store.alert)
        #expect(alert.actionTitle == "Reiniciar igual")
        #expect(alert.isDestructive)
        #expect(alert.message.contains("Esc"))
        #expect(f.rt.terminal === old) // todavía no se cortó nada
        #expect(f.rt.status == .working)
        alert.action?()
        #expect(f.rt.terminal !== old)
        #expect(f.rt.status == .idle)
    }

    @Test("⌘. con un agente trabajando pregunta antes de detener")
    func stopWorking() throws {
        let f = try InterruptFixture(.codex)
        f.store.userInput(f.id, [13])
        f.store.requestStop(f.id)
        #expect(f.store.alert?.actionTitle == "Detener igual")
        #expect(f.store.alert?.title == "«\(f.store.sessionContext(f.id)?.session.name ?? "")» está trabajando")
        #expect(f.rt.status == .working)
        #expect(f.rt.terminal != nil)
    }

    @Test("⌘W, ⌘R y ⌘. preguntan también si la sesión «Necesita permiso»")
    func attentionAsks() throws {
        let f = try InterruptFixture()
        f.permission()
        #expect(f.rt.status == .attention)
        f.store.requestArchive(f.id)
        #expect(f.store.alert?.actionTitle == "Archivar igual")
        #expect(f.store.alert?.title.hasSuffix("necesita permiso") == true)
        #expect(!f.isArchived)
        f.store.alert = nil
        f.store.requestRestart(f.id)
        #expect(f.store.alert?.actionTitle == "Reiniciar igual")
        f.store.alert = nil
        f.store.requestStop(f.id)
        #expect(f.store.alert?.actionTitle == "Detener igual")
        #expect(f.rt.status == .attention)
    }

    @Test("Con un agente listo o esperando tu turno, ⌘W, ⌘R y ⌘. no preguntan")
    func idleDoesNotAsk() throws {
        let f = try InterruptFixture()
        #expect(f.rt.status == .idle)
        let old = try #require(f.rt.terminal)
        f.store.requestRestart(f.id)
        #expect(f.store.alert == nil)
        #expect(f.rt.terminal !== old)
        f.store.requestStop(f.id)
        #expect(f.store.alert == nil)
        f.store.requestArchive(f.id)
        #expect(f.store.alert == nil)
        #expect(f.isArchived)
    }

    @Test("Una Terminal sin proceso en primer plano se archiva sin preguntar")
    func idleTerminal() throws {
        let f = try InterruptFixture(.shell)
        #expect(f.store.interruptConfirmation(.archive, of: f.id) == nil)
        f.store.requestArchive(f.id)
        #expect(f.store.alert == nil)
        #expect(f.isArchived)
    }

    @Test("Al salir, avisa también de las que esperan permiso")
    func quitCountsPermission() throws {
        let f = try InterruptFixture()
        f.permission()
        var asked: [String] = []
        let reply = HiveAppDelegate.terminateReply(store: f.store) { asked.append($0); return false }
        #expect(reply == .terminateCancel)
        #expect(asked == ["Hay una sesión esperando tu permiso"])
        #expect(QuitWarning.message(working: 1, commands: 2, permission: 1, processes: 1)
            == "Hay una sesión trabajando, una sesión esperando tu permiso, un proceso corriendo en una terminal y 2 comandos corriendo")
        #expect(QuitWarning.message(working: 0, commands: 0, processes: 3) == "Hay 3 procesos corriendo en terminales")
    }

    @Test("Una Terminal con un proceso corriendo (no el shell en el prompt) pregunta antes de archivarla")
    func terminalWithJob() async throws {
        let world = TestWorld()
        var real = world.environment
        real.processes = TerminalProcessStarter()
        real.loginShell = "/bin/zsh"
        let store = AppStore(environment: real)
        let branch = try #require(store.scratchProject?.branches.first)
        store.requestNewSession(branchId: branch.id, kind: .shell)
        let session = try #require(store.scratchProject?.branches.first?.sessions.last)
        store.activate(session.id)
        let rt = try #require(store.runtimes[session.id])
        let terminal = try #require(rt.terminal)
        defer { terminal.hangUp(grace: 0.4) }
        #expect(await waitUntil { terminal.isProcessRunning })
        // El shell solo, esperando en el prompt: no hay nada que cortar.
        #expect(terminal.foregroundJob == nil)

        terminal.sendInput(Array("sleep 30\r".utf8)[...])
        #expect(await waitUntil { terminal.foregroundJob == "sleep" })
        #expect(store.busyTerminalsCount == 1)
        store.requestArchive(session.id)
        let alert = try #require(store.alert)
        #expect(alert.title == "«sleep» está corriendo en «\(session.name)»")
        #expect(alert.actionTitle == "Archivar igual")
        #expect(store.sessionContext(session.id)?.session.isArchived == false)
        store.alert = nil

        // Ctrl+C: vuelve al prompt y ya se puede cerrar sin preguntar.
        terminal.sendInput([3])
        #expect(await waitUntil { terminal.foregroundJob == nil })
        #expect(store.interruptConfirmation(.archive, of: session.id) == nil)
        #expect(store.busyTerminalsCount == 0)
        terminal.sendInput(Array("exit\r".utf8)[...])
        #expect(await waitUntil { !terminal.isProcessRunning })
    }

    @Test("⌘K sigue siendo el buscador y «Limpiar» queda en ⌥⌘K y en el clic derecho de la terminal")
    func clearStaysOnOptionCommandK() {
        #expect(HiveCommands.Shortcut.search.description == "⌘K")
        #expect(HiveCommands.Shortcut.clearTerminal.description == "⌥⌘K")
        let shell = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let menu = TerminalContextMenu.menu(for: shell, at: .zero)
        #expect(menu.items.contains { $0.title == "Limpiar" && $0.action == #selector(HiveTerminalView.clearTerminal(_:)) })
    }
}
