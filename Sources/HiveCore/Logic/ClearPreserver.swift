import Foundation

/// Filtro de la salida de un agente: si borra pantalla y scroll justo después de un Enter
/// (como `/clear`), en lugar de perder todo deja la pantalla en el scroll con una divisoria.
/// Si el borrado llega sin un Enter reciente (por ejemplo, al redimensionar), no lo toca.
public struct ClearPreserver: Sendable {
    public static let eraseScreen: [UInt8] = [0x1B, 0x5B, 0x32, 0x4A]     // ESC[2J
    public static let eraseScrollback: [UInt8] = [0x1B, 0x5B, 0x33, 0x4A] // ESC[3J
    /// Cuánto después de un Enter se considera que el borrado vino de un comando.
    public static let window: TimeInterval = 4

    /// El scroll recuperado por Hive pertenece a toda la conversación, no al proceso nuevo.
    /// Sus borrados de arranque o redibujado no pueden eliminarlo, aunque no haya un Enter reciente.
    public var protectsScrollback = false

    private var carry: [UInt8] = []
    private var lastEnter: Date = .distantPast

    public init() {}

    public mutating func userPressedEnter(at date: Date) {
        lastEnter = date
    }

    /// Procesa un bloque de salida. `rows`/`cols` son el tamaño actual de la terminal.
    public mutating func process(_ slice: ArraySlice<UInt8>, now: Date, rows: Int, cols: Int) -> [UInt8] {
        var bytes = carry + Array(slice)
        carry = []
        // Si el bloque termina a mitad de una secuencia ESC[..., la guardamos para el siguiente.
        if let esc = bytes.lastIndex(of: 0x1B), bytes.count - esc <= 6, Self.isIncompleteCSI(bytes[esc...]) {
            carry = Array(bytes[esc...])
            bytes.removeSubrange(esc...)
        }
        let recentEnter = now.timeIntervalSince(lastEnter) < Self.window
        // Si el bloque termina justo en "borrar pantalla", esperamos al siguiente para saber si viene
        // "borrar scroll" (si no, se borraría la pantalla antes de poder guardarla).
        if recentEnter, bytes.count >= Self.eraseScreen.count, Array(bytes.suffix(Self.eraseScreen.count)) == Self.eraseScreen {
            carry = Self.eraseScreen + carry
            bytes.removeLast(Self.eraseScreen.count)
        }
        guard recentEnter, let scrollbackRange = bytes.firstRange(of: Self.eraseScrollback) else { return protect(bytes) }

        var result: [UInt8] = []
        let push = Self.pushScreenToScrollback(rows: rows, cols: cols, time: now)
        if let screenRange = bytes.firstRange(of: Self.eraseScreen), screenRange.lowerBound < scrollbackRange.lowerBound {
            // Lo de antes del borrado, la pantalla al scroll y el borrado de pantalla sin tocar el scroll.
            result += bytes[..<screenRange.lowerBound]
            result += push
            result += bytes[screenRange.lowerBound..<scrollbackRange.lowerBound]
        } else {
            result += bytes[..<scrollbackRange.lowerBound]
            result += push
        }
        result += bytes[scrollbackRange.upperBound...]
        lastEnter = .distantPast // un solo /clear por Enter
        return protect(result)
    }

    private func protect(_ bytes: [UInt8]) -> [UInt8] {
        guard protectsScrollback else { return bytes }
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index...].starts(with: Self.eraseScrollback) {
                index += Self.eraseScrollback.count
            } else if bytes[index...].starts(with: [0x1B, 0x63]) {
                // RIS recrea ambos buffers. Un reset de modos + pantalla mantiene el scroll de Hive.
                result += Array("\u{1B}[!p\u{1B}[H\u{1B}[2J".utf8)
                index += 2
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return result
    }

    /// Lo que quedó retenido esperando el siguiente bloque (para las pruebas).
    public var pending: [UInt8] { carry }

    /// Baja a la última fila, escribe una divisoria y hace scroll hasta que la pantalla quede vacía:
    /// todo lo que se veía pasa al historial de scroll.
    static func pushScreenToScrollback(rows: Int, cols: Int, time: Date) -> [UInt8] {
        let rows = max(rows, 1)
        let label = " /clear · \(time.formatted(date: .omitted, time: .shortened)) "
        let side = max((cols - label.count) / 2, 2)
        let line = String(repeating: "─", count: side) + label + String(repeating: "─", count: side)
        var text = "\u{1B}[\(rows);1H\r\n\u{1B}[2m\(line.prefix(max(cols - 1, 10)))\u{1B}[0m"
        text += String(repeating: "\r\n", count: rows)
        text += "\u{1B}[H"
        return Array(text.utf8)
    }

    /// ESC solo, o ESC[ con parámetros pero sin el byte final.
    static func isIncompleteCSI(_ bytes: ArraySlice<UInt8>) -> Bool {
        let rest = bytes.dropFirst()
        guard let first = rest.first else { return true }
        guard first == 0x5B else { return false }
        return rest.dropFirst().allSatisfy { $0 >= 0x30 && $0 <= 0x3F }
    }
}
