import AppKit
import HiveCore

/// Escribe en una sesión lo que le respondiste desde un aviso, como si lo hubieras tipeado.
@MainActor
enum ReplySender {
    /// Cómo terminó el envío.
    enum Outcome: Equatable {
        /// Se escribió en la terminal y se mandó con Enter.
        case typed
        /// La sesión no estaba corriendo: se abrió y el texto quedó en el portapapeles.
        case copied
        /// La sesión ya no existe.
        case missing
    }

    static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC [200~
    static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // ESC [201~

    /// El texto a escribir. Si el programa activó el pegado entre corchetes, va así: un texto con
    /// saltos de línea llega entero en lugar de mandarse de a una línea.
    static func payload(_ text: String, bracketed: Bool) -> [UInt8] {
        let bytes = Array(text.utf8)
        return bracketed ? pasteStart + bytes + pasteEnd : bytes
    }

    /// Manda `text` a la sesión. El Enter va un instante después (como al tipear), por la
    /// misma entrada que el teclado: así el store la pasa a «Trabajando» por el camino normal.
    @discardableResult
    static func send(_ text: String, sessionId: UUID, store: AppStore, pasteboard: NSPasteboard = .general,
                     submitDelay: TimeInterval = 0.03,
                     activateApp: (() -> Void)? = nil) -> Outcome {
        guard let ctx = store.sessionContext(sessionId) else { return .missing }
        if let rt = store.runtimes[sessionId], rt.isRunning, let terminal = rt.terminal {
            let bracketed = terminal.terminalStateSnapshot().bracketedPasteMode
            terminal.sendInput(payload(text, bracketed: bracketed)[...])
            DispatchQueue.main.asyncAfter(deadline: .now() + submitDelay) { [weak terminal] in
                terminal?.sendInput([13])
            }
            return .typed
        }
        // Sin proceso no hay a quién escribirle: abrimos la sesión y dejamos el texto a mano.
        store.setExpanded(ctx.project.id, true)
        store.setExpanded(ctx.branch.id, true)
        store.select(.session(sessionId))
        if let activateApp { activateApp() } else { NSApp?.activate(ignoringOtherApps: true) }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        store.alert = AppAlert(title: "Copié tu respuesta", message: "Pegala cuando arranque la sesión.")
        return .copied
    }
}
