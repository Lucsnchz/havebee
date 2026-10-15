import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Registra lo que avisa la terminal.
@MainActor
final class TerminalProbe: HiveTerminalDelegate {
    var title: String?
    var exitCode: Int32??

    func terminalTitleChanged(_ terminal: HiveTerminalView, title: String) { self.title = title }
    func terminalProcessTerminated(_ terminal: HiveTerminalView, exitCode: Int32?) { self.exitCode = .some(exitCode) }
}

@MainActor
@Suite("Terminal (procesos reales)", .serialized)
struct TerminalTests {
    func makeTerminal(scrollback: Int = 10_000) -> HiveTerminalView {
        _ = NSApplication.shared
        let view = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 220), scrollback: scrollback)
        TerminalTheme.apply(to: view)
        return view
    }

    func start(_ view: HiveTerminalView, _ script: String) {
        TerminalProcessStarter().start(view, executable: "/bin/sh", args: ["-c", script],
                                       environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"], directory: "/tmp")
    }

    @Test("Muestra la salida del proceso y avisa cuando termina con su código")
    func output() async {
        let view = makeTerminal()
        let probe = TerminalProbe()
        view.processDelegate = probe
        var outputs = 0
        view.setProcessOutputHandler { outputs += 1 }
        start(view, "printf 'hola desde el proceso\\n'; printf '\\033]0;Mi título\\007'; exit 3")
        #expect(await waitUntil { probe.exitCode != nil })
        #expect(probe.exitCode == .some(3))
        #expect(view.fullText().contains("hola desde el proceso"))
        #expect(probe.title == "Mi título")
        #expect(outputs > 0)
    }

    @Test("Lo que escribís le llega al proceso")
    func input() async {
        let view = makeTerminal()
        let probe = TerminalProbe()
        view.processDelegate = probe
        var typed: [UInt8] = []
        view.onUserInput = { typed += $0 }
        start(view, "read linea; printf 'recibí: %s\\n' \"$linea\"")
        try? await Task.sleep(nanoseconds: 200_000_000)
        view.sendInput(Array("abeja\r".utf8)[...])
        #expect(await waitUntil { probe.exitCode != nil })
        #expect(view.fullText().contains("recibí: abeja"))
        #expect(typed == Array("abeja\r".utf8))
    }

    @Test("/clear después de Enter conserva lo anterior en el scroll, con la divisoria")
    func preservesOnClear() {
        let view = makeTerminal()
        view.preservesScrollbackOnClear = true
        view.receive(Array("charla uno\r\ncharla dos\r\n".utf8)[...])
        view.sendInput([13]) // el Enter del /clear (sin proceso: no hace nada más)
        view.receive(Array("\u{1B}[2J\u{1B}[3J\u{1B}[Hconversación nueva".utf8)[...])
        let text = view.fullText()
        let positions = ["charla uno", "/clear", "conversación nueva"].map { text.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        if positions.allSatisfy({ $0 != nil }) {
            #expect(positions[0]! < positions[1]! && positions[1]! < positions[2]!)
        }
    }

    @Test("Sin el filtro (o sin Enter) el borrado funciona como siempre")
    func normalClear() {
        let plain = makeTerminal()
        plain.receive(Array("vieja\r\n".utf8)[...])
        plain.sendInput([13])
        plain.receive(Array("\u{1B}[2J\u{1B}[3J\u{1B}[Hnueva".utf8)[...])
        #expect(!plain.fullText().contains("vieja"))

        let noEnter = makeTerminal()
        noEnter.preservesScrollbackOnClear = true
        noEnter.receive(Array("vieja\r\n".utf8)[...])
        noEnter.receive(Array("\u{1B}[2J\u{1B}[3J\u{1B}[Hnueva".utf8)[...])
        #expect(!noEnter.fullText().contains("vieja") && noEnter.fullText().contains("nueva"))
    }

    @Test("Guarda mucho más que las 500 líneas de SwiftTerm")
    func longScrollback() {
        let view = makeTerminal()
        let lines = (1...3000).map { "línea \($0)" }.joined(separator: "\r\n")
        view.receive(Array(lines.utf8)[...])
        let text = view.fullText()
        #expect(text.contains("línea 1\n") || text.hasPrefix("línea 1"))
        #expect(text.contains("línea 3000"))

        let small = makeTerminal(scrollback: 100)
        small.receive(Array(lines.utf8)[...])
        #expect(!small.fullText().contains("línea 1\n"))
    }

    @Test("Terminar el proceso avisa")
    func terminate() async {
        let view = makeTerminal()
        let probe = TerminalProbe()
        view.processDelegate = probe
        start(view, "sleep 30")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(view.isProcessRunning)
        view.terminate()
        #expect(await waitUntil { probe.exitCode != nil })
        #expect(!view.isProcessRunning)
    }

    @Test("Una sesión real: el store marca terminada la sesión cuando el proceso sale")
    func storeIntegration() async throws {
        let world = TestWorld()
        let repo = GitRepo()
        let environment = world.environment
        // Este test lanza procesos de verdad.
        var real = environment
        real.processes = TerminalProcessStarter()
        real.loginShell = "/bin/sh"
        let store = AppStore(environment: real)
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .shell)
        let session = try #require(store.project(project.id)?.allSessions.first)
        store.activate(session.id)
        let rt = try #require(store.runtimes[session.id])
        #expect(rt.isRunning)
        rt.terminal?.sendInput(Array("exit 4\r".utf8)[...])
        #expect(await waitUntil { rt.status == .exited(4) })
        #expect(!rt.isRunning)
    }

    @Test("Reiniciar un agente espera a que termine el proceso viejo y no muestra «terminada» en el medio")
    func relaunchWaitsForExit() async throws {
        let real = try await RealSessionStore(kind: .claude)
        let store = real.store
        let rt = try #require(store.runtimes[real.session.id])
        let old = try #require(rt.terminal)
        #expect(await waitUntil { old.fullText().contains("listo") })
        store.relaunch(real.session.id)
        store.relaunch(real.session.id) // un doble clic no lanza dos veces
        #expect(rt.terminal === old) // todavía esperando al proceso viejo
        #expect(await waitUntil { rt.terminal !== old })
        #expect(!old.isProcessRunning)
        #expect(old.fullText().contains("chau"))
        #expect(rt.status == .idle && rt.isRunning)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rt.status == .idle) // el aviso de fin del proceso viejo no pisa a la nueva
        store.stop(real.session.id)
        #expect(await waitUntil { rt.status == .exited(0) })
    }

    @Test("Si la archivás mientras se reinicia, no se vuelve a lanzar")
    func archiveDuringRelaunch() async throws {
        let real = try await RealSessionStore(kind: .claude)
        let store = real.store
        let rt = try #require(store.runtimes[real.session.id])
        let old = try #require(rt.terminal)
        #expect(await waitUntil { old.fullText().contains("listo") })
        store.relaunch(real.session.id)
        store.archive(real.session.id)
        #expect(await waitUntil { store.relaunching.isEmpty })
        #expect(!old.isProcessRunning)
        #expect(rt.terminal == nil && !rt.isRunning)
        #expect(store.sessionContext(real.session.id)?.session.isArchived == true)
    }

    @Test("La salida de la terminal marca la última actividad")
    func outputTouchesActivity() async throws {
        let real = try await RealSessionStore(kind: .shell)
        let rt = try #require(real.store.runtimes[real.session.id])
        let before = Date()
        rt.terminal?.sendInput(Array("echo hola\r".utf8)[...])
        #expect(await waitUntil { rt.lastOutput >= before })
        rt.terminal?.sendInput(Array("exit\r".utf8)[...])
        #expect(await waitUntil { !rt.isRunning })
    }
}

/// Un store que lanza procesos de verdad, con una sesión abierta. Para los agentes usa un «claude»
/// falso (un script que saluda, espera y se despide con SIGTERM): nunca el de verdad.
@MainActor
private final class RealSessionStore {
    let world = TestWorld()
    let repo = GitRepo()
    let bin = TempDir("hive-bin")
    let store: AppStore
    let session: Session

    init(kind: SessionKind) async throws {
        let script = bin.write("claude", "#!/bin/sh\ntrap 'echo chau; exit 0' TERM\necho listo\nwhile :; do sleep 0.05; done\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var real = world.environment
        real.processes = TerminalProcessStarter()
        real.loginShell = "/bin/sh"
        real.cachedLoginPATH = "\(bin.path):/usr/bin:/bin"
        store = AppStore(environment: real)
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: kind)
        session = try #require(store.project(project.id)?.allSessions.first)
        store.activate(session.id)
    }
}
