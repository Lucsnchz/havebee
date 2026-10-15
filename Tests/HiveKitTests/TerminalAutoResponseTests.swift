import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Respuestas automáticas de la terminal", .serialized)
struct TerminalAutoResponseTests {
    /// Una terminal sin proceso que registra lo tipeado y lo que le llegaría al proceso.
    @MainActor
    final class Probe {
        let view: HiveTerminalView
        var typed: [[UInt8]] = []
        var toProcess: [[UInt8]] = []

        init(agent: Bool = true) {
            _ = NSApplication.shared
            view = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), scrollback: 1_000)
            view.preservesScrollbackOnClear = agent
            view.onUserInput = { [unowned self] in typed.append(Array($0)) }
            view.onProcessInput = { [unowned self] in toProcess.append(Array($0)) }
        }

        var processText: String { toProcess.map { String(decoding: $0, as: UTF8.self) }.joined() }
    }

    @Test("DSR (posición del cursor) se contesta directo al proceso, sin pasar por onUserInput")
    func cursorPosition() {
        let probe = Probe()
        probe.view.receive(Array("hola\u{1B}[6n".utf8)[...])
        #expect(probe.processText.contains("\u{1B}[1;5R"))
        #expect(probe.typed.isEmpty)
    }

    @Test("DA1 (atributos de la terminal) también va directo")
    func deviceAttributes() {
        let probe = Probe()
        probe.view.receive(Array("\u{1B}[c".utf8)[...])
        #expect(probe.processText.hasPrefix("\u{1B}[?"))
        #expect(probe.typed.isEmpty)
    }

    @Test("Una respuesta automática no habilita el /clear: solo un Enter tipeado")
    func notAnEnterForClear() {
        let probe = Probe()
        probe.view.receive(Array("vieja\r\n".utf8)[...])
        probe.view.receive(Array("\u{1B}[6n\u{1B}[c".utf8)[...])
        probe.view.receive(Array("\u{1B}[2J\u{1B}[3J\u{1B}[Hnueva".utf8)[...])
        let text = probe.view.fullText()
        #expect(!text.contains("vieja") && text.contains("nueva"))
    }

    @Test("Lo tipeado sí pasa por onUserInput y llega al proceso")
    func typedInput() {
        let probe = Probe()
        probe.view.sendInput(Array("ls\r".utf8)[...])
        #expect(probe.typed == [Array("ls\r".utf8)])
        #expect(probe.toProcess == [Array("ls\r".utf8)])
    }

    @Test("Pegar es del usuario: pasa por onUserInput")
    func pasteIsUserInput() async {
        let probe = Probe()
        probe.view.pastingAsUser { probe.view.pasteText("hola") }
        // Al proceso llega en el acto; el aviso de tipeo, un instante después.
        #expect(probe.toProcess == [Array("hola".utf8)])
        #expect(await waitUntil { probe.typed == [Array("hola".utf8)] })
    }

    @Test("Quien escucha lo pegado puede consultar la terminal (el lock de SwiftTerm ya se soltó)")
    func pasteListenerCanReadTerminal() async {
        let probe = Probe()
        probe.view.receive(Array("prompt$ ".utf8)[...])
        var firstRow: [String] = []
        // SwiftTerm manda lo pegado con su lock tomado y no es recursivo: si el aviso llegara
        // ahí adentro, leer la terminal haría caer la app.
        probe.view.onUserInput = { [unowned view = probe.view] _ in firstRow = view.visibleRowsText(0..<1) }
        probe.view.pastingAsUser { probe.view.pasteText("ls") }
        #expect(await waitUntil { !firstRow.isEmpty })
        #expect(firstRow.first?.hasPrefix("prompt$") == true)
    }

    @Test("Nadie puede leer el portapapeles con OSC 52")
    func clipboardReadDenied() async {
        let probe = Probe()
        #expect(probe.view.clipboardRead(source: probe.view) == nil)
        probe.view.receive(Array("\u{1B}]52;c;?\u{07}".utf8)[...])
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!probe.processText.contains("]52;"))
    }
}
