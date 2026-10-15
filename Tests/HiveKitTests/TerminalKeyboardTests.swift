import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Una terminal en una ventana fuera de pantalla, con un registro de lo que manda al proceso.
@MainActor
private final class KeyboardHarness {
    let defaults: UserDefaults
    private let suite = "hive-keyboard-\(UUID().uuidString)"
    let view: HiveTerminalView
    let window: NSWindow
    private(set) var sends: [[UInt8]] = []
    private(set) var enters = 0

    init(agent: Bool, optionKey: String? = nil) {
        _ = NSApplication.shared
        defaults = UserDefaults(suiteName: suite)!
        if let optionKey { defaults.set(optionKey, forKey: "terminalOptionKey") }
        view = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), scrollback: 1_000)
        TerminalTheme.apply(to: view, defaults: defaults)
        view.preservesScrollbackOnClear = agent
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        view.onUserInput = { [unowned self] data in
            sends.append(Array(data))
            if TerminalInput.isSubmit(data) { enters += 1 }
        }
    }

    func close() {
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }

    var bytes: [UInt8] { sends.flatMap { $0 } }

    func key(_ keyCode: UInt16, _ characters: String, ignoring: String? = nil, _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode)!
        view.processKeyEvent(event)
    }

    func reset() { sends = [] }
}

private let kReturn: UInt16 = 0x24
private let kLeft: UInt16 = 0x7B
private let kRight: UInt16 = 0x7C
private let kQ: UInt16 = 0x0C
private let kE: UInt16 = 0x0E
private let kA: UInt16 = 0x00
private let kDelete: UInt16 = 0x33
private let kSpace: UInt16 = 0x31
private let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
private let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)

@MainActor
@Suite("Teclado de la terminal (eventos simulados)", .serialized)
struct TerminalKeyboardTests {
    @Test("⌥Q con teclado latinoamericano escribe @ (0x40), no ESC q")
    func optionAt() {
        let h = KeyboardHarness(agent: true)
        defer { h.close() }
        h.key(kQ, "@", ignoring: "q", .option)
        #expect(h.bytes == [0x40])
    }

    @Test("⌥ con otros símbolos del teclado latino: [ ] { } | \\ ~")
    func optionSymbols() {
        let h = KeyboardHarness(agent: false)
        defer { h.close() }
        for symbol in ["[", "]", "{", "}", "|", "\\", "~", "ñ"] {
            h.reset()
            h.key(0x2C, symbol, ignoring: "x", .option)
            #expect(h.bytes == Array(symbol.utf8), "⌥ debería escribir \(symbol)")
        }
    }

    @Test("⌥e (tecla muerta de la tilde) no manda ESC e: la «á» la arma macOS")
    func deadKey() {
        let h = KeyboardHarness(agent: true)
        defer { h.close() }
        // Así llega una tecla muerta: sin caracteres. Con Meta habría mandado ESC e.
        h.key(kE, "", ignoring: "e", .option)
        #expect(h.bytes.isEmpty)
        // Los eventos simulados no pasan por el estado de teclas muertas del sistema: acá llega
        // la «á» como la entrega macOS al tocar la a, y tiene que salir tal cual en UTF-8.
        h.key(kA, "á", ignoring: "a")
        #expect(String(decoding: h.bytes, as: UTF8.self) == "á")
    }

    @Test("⌥← y ⌥→ siguen saltando palabras (ESC b / ESC f) y ⌥⌫ sigue siendo Meta")
    func optionArrows() {
        let h = KeyboardHarness(agent: true)
        defer { h.close() }
        h.key(kLeft, left, [.option, .numericPad, .function])
        #expect(h.bytes == [0x1B, 0x62])
        h.reset()
        h.key(kRight, right, [.option, .numericPad, .function])
        #expect(h.bytes == [0x1B, 0x66])
        h.reset()
        h.key(kDelete, "\u{7F}", [.option])
        #expect(h.bytes.first == 0x1B)
    }

    @Test("Shift+Enter en un agente: ESC CR en un solo envío y no cuenta como Enter")
    func shiftEnterAgent() {
        let h = KeyboardHarness(agent: true)
        defer { h.close() }
        h.key(kReturn, "\r", [.shift])
        #expect(h.sends == [[0x1B, 0x0D]])
        #expect(h.enters == 0)
        h.reset()
        h.key(kReturn, "\r", [.option])
        #expect(h.sends == [[0x1B, 0x0D]])
        #expect(h.enters == 0)
    }

    @Test("Enter solo manda CR y cuenta como Enter")
    func plainEnter() {
        let h = KeyboardHarness(agent: true)
        defer { h.close() }
        h.key(kReturn, "\r")
        #expect(h.bytes == [0x0D])
        #expect(h.enters == 1)
    }

    @Test("Con kitty activo, Shift+Enter lo codifica la terminal (CSI 13;2u)")
    func shiftEnterKitty() {
        let h = KeyboardHarness(agent: true)
        defer { h.close() }
        h.view.receive(Array("\u{1B}[>1u".utf8)[...])
        #expect(!h.view.keyboardEnhancementFlags.isEmpty)
        h.key(kReturn, "\r", [.shift])
        #expect(String(decoding: h.bytes, as: UTF8.self) == "\u{1B}[13;2u")
        #expect(h.enters == 0)
    }

    @Test("En una terminal común, Shift+Enter es Enter")
    func shiftEnterShell() {
        let h = KeyboardHarness(agent: false)
        defer { h.close() }
        h.key(kReturn, "\r", [.shift])
        #expect(h.bytes == [0x0D])
    }

    @Test("Con ⌥ como Meta (ajuste), ⌥Q manda ESC q como antes")
    func metaSetting() {
        let h = KeyboardHarness(agent: true, optionKey: "meta")
        defer { h.close() }
        h.key(kQ, "@", ignoring: "q", .option)
        #expect(h.bytes == [0x1B, 0x71])
        h.reset()
        h.key(kE, "", ignoring: "e", .option)
        #expect(h.bytes == [0x1B, 0x65])
    }

    @Test("⌥Espacio escribe un espacio común")
    func optionSpace() {
        let h = KeyboardHarness(agent: true)
        defer { h.close() }
        h.key(kSpace, "\u{A0}", ignoring: " ", .option)
        #expect(h.bytes == [0x20])
    }
}
