import Foundation
import Testing
@testable import HiveCore

@Suite("Teclado de la terminal")
struct TerminalKeysTests {
    func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }

    @Test("Enter manda; ESC CR (Shift/⌥ Enter) no")
    func submit() {
        #expect(TerminalInput.isSubmit([0x0D]))
        #expect(TerminalInput.isSubmit(bytes("hola\r")))
        #expect(!TerminalInput.isSubmit([0x1B, 0x0D]))
        #expect(!TerminalInput.isSubmit(bytes("hola")))
        #expect(!TerminalInput.isSubmit([]))
        // Un ESC CR seguido de un Enter de verdad sí manda.
        #expect(TerminalInput.isSubmit([0x1B, 0x0D, 0x61, 0x0D]))
        // ESC suelto al final no rompe nada.
        #expect(!TerminalInput.isSubmit([0x61, 0x1B]))
    }

    @Test("Lo pegado (ESC[200~ … ESC[201~) no cuenta como Enter, lo que viene después sí")
    func bracketedPaste() {
        #expect(!TerminalInput.isSubmit(bytes("\u{1B}[200~línea uno\rlínea dos\r\u{1B}[201~")))
        #expect(!TerminalInput.isSubmit(bytes("\u{1B}[200~sin cerrar\r")))
        #expect(TerminalInput.isSubmit(bytes("\u{1B}[200~pegado\u{1B}[201~\r")))
    }

    @Test("CSI-u: Enter sin modificadores manda; con Shift, o al soltar la tecla, no")
    func kitty() {
        #expect(TerminalInput.isSubmit(bytes("\u{1B}[13u")))
        #expect(TerminalInput.isSubmit(bytes("\u{1B}[13;1u")))
        #expect(TerminalInput.isSubmit(bytes("\u{1B}[13;1:1u")))
        #expect(TerminalInput.isSubmit(bytes("\u{1B}[13;65u")))      // con Bloq Mayús
        #expect(!TerminalInput.isSubmit(bytes("\u{1B}[13;2u")))      // Shift+Enter
        #expect(!TerminalInput.isSubmit(bytes("\u{1B}[13;3u")))      // ⌥Enter
        #expect(!TerminalInput.isSubmit(bytes("\u{1B}[13;1:3u")))    // soltar Enter
        #expect(!TerminalInput.isSubmit(bytes("\u{1B}[97;5u")))      // Ctrl+a
        // Una secuencia con 13 en los parámetros no es un CR.
        #expect(!TerminalInput.isSubmit(bytes("\u{1B}[13;1R")))
    }

    @Test("Esc suelto, y ESC[27u de kitty")
    func loneEscape() {
        #expect(TerminalInput.isLoneEscape([0x1B]))
        #expect(TerminalInput.isLoneEscape(bytes("\u{1B}[27u")))
        #expect(TerminalInput.isLoneEscape(bytes("\u{1B}[27;1u")))
        #expect(!TerminalInput.isLoneEscape(bytes("\u{1B}[27;2u")))
        #expect(!TerminalInput.isLoneEscape([0x1B, 0x62]))              // ⌥← (ESC b)
        #expect(!TerminalInput.isLoneEscape(bytes("\u{1B}[A")))          // flecha arriba
        #expect(!TerminalInput.isLoneEscape([]))
        #expect(!TerminalInput.isLoneEscape([0x61]))
    }

    @Test("Shift/⌥ Enter: ESC CR solo si kitty está apagado")
    func modifiedReturn() {
        #expect(TerminalKeys.modifiedReturn(shift: true, option: false, kittyActive: false) == [0x1B, 0x0D])
        #expect(TerminalKeys.modifiedReturn(shift: false, option: true, kittyActive: false) == [0x1B, 0x0D])
        #expect(TerminalKeys.modifiedReturn(shift: true, option: false, kittyActive: true) == nil)
        #expect(TerminalKeys.modifiedReturn(shift: false, option: false, kittyActive: false) == nil)
    }

    @Test("⌥ compone letras y símbolos; flechas, Return, ⌫, Esc y Tab siguen como Meta")
    func optionCompose() {
        let q: UInt16 = 0x0C, e: UInt16 = 0x0E, n: UInt16 = 0x2D, two: UInt16 = 0x13
        for code in [q, e, n, two] { #expect(TerminalKeys.optionShouldCompose(keyCode: code)) }
        let codes = TerminalKeys.Code.self
        for code in [codes.leftArrow, codes.rightArrow, codes.upArrow, codes.downArrow, codes.returnKey,
                     codes.keypadEnter, codes.delete, codes.escape, codes.tab] {
            #expect(!TerminalKeys.optionShouldCompose(keyCode: code))
        }
    }
}
