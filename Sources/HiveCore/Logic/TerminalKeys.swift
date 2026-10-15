import Foundation

/// Lectura de los bytes que el teclado le manda al proceso de una terminal.
public enum TerminalInput {
    private static let esc: UInt8 = 0x1B
    private static let cr: UInt8 = 0x0D

    /// Si la entrada manda lo escrito, como un Enter de verdad. Cuenta un CR que no viene
    /// después de ESC (ESC CR es el salto de línea de Shift+Enter y ⌥Enter) ni está dentro de
    /// un pegado (ESC[200~ … ESC[201~). Con el protocolo de teclado de kitty, Enter sin
    /// modificadores (ESC[13u) también cuenta; con modificadores (ESC[13;2u) no.
    public static func isSubmit(_ bytes: ArraySlice<UInt8>) -> Bool {
        var i = bytes.startIndex
        var inPaste = false
        while i < bytes.endIndex {
            let byte = bytes[i]
            if byte == esc {
                let next = bytes.index(after: i)
                guard next < bytes.endIndex else { return false }
                if bytes[next] == cr {
                    // ESC CR: salto de línea, no envío.
                    i = bytes.index(after: next)
                    continue
                }
                if bytes[next] == UInt8(ascii: "["), let csi = parseCSI(bytes, from: bytes.index(after: next)) {
                    switch (csi.final, csi.parameters) {
                    case (UInt8(ascii: "~"), "200"): inPaste = true
                    case (UInt8(ascii: "~"), "201"): inPaste = false
                    case (UInt8(ascii: "u"), let parameters) where !inPaste && isUnmodifiedKittyKey(parameters, code: 13):
                        return true
                    default: break
                    }
                    i = csi.end
                    continue
                }
                i = next
                continue
            }
            if byte == cr && !inPaste { return true }
            i = bytes.index(after: i)
        }
        return false
    }

    /// Si la entrada es solo la tecla Esc: el byte ESC suelto o, con el protocolo de kitty, ESC[27u.
    public static func isLoneEscape(_ bytes: ArraySlice<UInt8>) -> Bool {
        if bytes.count == 1 { return bytes.first == esc }
        guard bytes.count > 3, bytes.first == esc, bytes[bytes.index(after: bytes.startIndex)] == UInt8(ascii: "["),
              let csi = parseCSI(bytes, from: bytes.index(bytes.startIndex, offsetBy: 2)),
              csi.end == bytes.endIndex, csi.final == UInt8(ascii: "u") else { return false }
        return isUnmodifiedKittyKey(csi.parameters, code: 27)
    }

    /// Una secuencia CSI que arranca en `start` (justo después de ESC[): parámetros y byte final.
    private static func parseCSI(_ bytes: ArraySlice<UInt8>, from start: Int) -> (parameters: String, final: UInt8, end: Int)? {
        var i = start
        while i < bytes.endIndex {
            let byte = bytes[i]
            if (0x40...0x7E).contains(byte) {
                let parameters = String(decoding: bytes[start..<i], as: UTF8.self)
                return (parameters, byte, bytes.index(after: i))
            }
            // Parámetros (0x30–0x3F) e intermedios (0x20–0x2F); cualquier otra cosa corta la secuencia.
            guard (0x20...0x3F).contains(byte) else { return nil }
            i = bytes.index(after: i)
        }
        return nil
    }

    /// `código[:alternativas];modificadores[:evento];texto` sin modificadores (ignora Bloq Mayús
    /// y Bloq Num) y como pulsación o repetición, no como soltar la tecla.
    private static func isUnmodifiedKittyKey(_ parameters: String, code: Int) -> Bool {
        let fields = parameters.split(separator: ";", omittingEmptySubsequences: false)
        guard let key = fields.first?.split(separator: ":").first, Int(key) == code else { return false }
        guard fields.count > 1, !fields[1].isEmpty else { return true }
        let parts = fields[1].split(separator: ":", omittingEmptySubsequences: false)
        let modifiers = Int(parts[0]) ?? 1
        let event = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        let locks = 64 | 128
        return (modifiers - 1) & ~locks == 0 && (event == 1 || event == 2)
    }
}

/// Decisiones del teclado de la terminal que no dependen de AppKit.
public enum TerminalKeys {
    /// Códigos de tecla de macOS (los mismos que `kVK_*` de Carbon).
    public enum Code {
        public static let returnKey: UInt16 = 0x24
        public static let keypadEnter: UInt16 = 0x4C
        public static let tab: UInt16 = 0x30
        public static let space: UInt16 = 0x31
        public static let delete: UInt16 = 0x33
        public static let escape: UInt16 = 0x35
        public static let forwardDelete: UInt16 = 0x75
        public static let home: UInt16 = 0x73
        public static let end: UInt16 = 0x77
        public static let pageUp: UInt16 = 0x74
        public static let pageDown: UInt16 = 0x79
        public static let leftArrow: UInt16 = 0x7B
        public static let rightArrow: UInt16 = 0x7C
        public static let downArrow: UInt16 = 0x7D
        public static let upArrow: UInt16 = 0x7E
        public static let functionKeys: Set<UInt16> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
    }

    /// Shift+Enter o ⌥Enter en un agente: ESC CR (salto de línea en el prompt de Claude y Codex)
    /// en un solo envío. Si el programa activó el protocolo de kitty, lo codifica la terminal.
    public static func modifiedReturn(shift: Bool, option: Bool, kittyActive: Bool) -> [UInt8]? {
        guard shift || option, !kittyActive else { return nil }
        return [0x1B, 0x0D]
    }

    /// ⌥← y ⌥→ sin Shift: ESC b y ESC f (palabra anterior y siguiente en zsh, bash, Claude y
    /// Codex). Si el programa activó el protocolo de kitty, lo codifica la terminal.
    public static func optionWordJump(keyCode: UInt16, shift: Bool, kittyActive: Bool) -> [UInt8]? {
        guard !shift, !kittyActive else { return nil }
        switch keyCode {
        case Code.leftArrow: return [0x1B, 0x62]
        case Code.rightArrow: return [0x1B, 0x66]
        default: return nil
        }
    }

    /// Si ⌥ con esta tecla tiene que escribir un carácter (ñ, tildes, @, corchetes) en lugar de
    /// funcionar como Meta. Las flechas, Return, ⌫, Esc, Tab y las teclas de función siguen
    /// siendo Meta: ⌥← y ⌥→ saltan palabras, ⌥⌫ borra una palabra.
    public static func optionShouldCompose(keyCode: UInt16) -> Bool {
        let meta: Set<UInt16> = [Code.returnKey, Code.keypadEnter, Code.tab, Code.delete, Code.escape, Code.forwardDelete,
                                 Code.home, Code.end, Code.pageUp, Code.pageDown,
                                 Code.leftArrow, Code.rightArrow, Code.downArrow, Code.upArrow]
        return !meta.contains(keyCode) && !Code.functionKeys.contains(keyCode)
    }
}
