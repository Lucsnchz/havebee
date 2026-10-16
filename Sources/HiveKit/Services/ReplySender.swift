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
        /// La sesión está pidiendo permiso: escribir ahí (y mandar Enter) podría aprobar el pedido
        /// sin querer. Se abrió y el texto quedó en el portapapeles.
        case heldForPermission
        /// La sesión ya no existe.
        case missing
    }

    static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC [200~
    static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // ESC [201~

    /// El texto a escribir. Si el programa activó el pegado entre corchetes, va así: un texto con
    /// saltos de línea llega entero en lugar de mandarse de a una línea.
    /// Sin caracteres de control (salvo saltos de línea y tabulaciones): un ESC en el texto podría
    /// cerrar el pegado antes de tiempo y lo que sigue llegaría como teclas, y un Ctrl-C o un
    /// retorno de carro cortarían o mandarían la respuesta a la mitad. Sin pegado entre corchetes,
    /// un salto de línea también la mandaría a la mitad, así que pasa a ser un espacio.
    static func payload(_ text: String, bracketed: Bool) -> [UInt8] {
        var clean = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                clean.append(bracketed ? scalar : " ")
            } else if scalar == "\t" || scalar.properties.generalCategory != .control {
                clean.append(scalar)
            }
        }
        let bytes = Array(String(clean).utf8)
        return bracketed ? pasteStart + bytes + pasteEnd : bytes
    }

    /// Manda `text` a la sesión. El Enter va un instante después (como al tipear), por la
    /// misma entrada que el teclado: así el store la pasa a «Trabajando» por el camino normal.
    @discardableResult
    static func send(_ text: String, sessionId: UUID, store: AppStore, pasteboard: NSPasteboard = .general,
                     submitDelay: TimeInterval = 0.03,
                     activateApp: (() -> Void)? = nil) -> Outcome {
        guard store.sessionContext(sessionId) != nil else { return .missing }
        if let rt = store.runtimes[sessionId], rt.isRunning, let terminal = rt.terminal {
            // Un aviso viejo de «Tu turno» puede llegar cuando la sesión ya pide permiso: el Enter
            // elegiría la opción marcada (casi siempre «Sí»). Mejor que lo veas vos.
            guard rt.status != .attention else {
                handOver(text, sessionId: sessionId, store: store, pasteboard: pasteboard, activateApp: activateApp,
                         alert: AppAlert(title: "La sesión está pidiendo permiso",
                                         message: "No escribí tu respuesta para no contestar el pedido sin querer. Fijate qué pide; tu respuesta quedó en el portapapeles."))
                return .heldForPermission
            }
            let bracketed = terminal.terminalStateSnapshot().bracketedPasteMode
            terminal.sendInput(payload(text, bracketed: bracketed)[...])
            DispatchQueue.main.asyncAfter(deadline: .now() + submitDelay) { [weak terminal] in
                terminal?.sendInput([13])
            }
            return .typed
        }
        // Sin proceso no hay a quién escribirle: abrimos la sesión y dejamos el texto a mano.
        handOver(text, sessionId: sessionId, store: store, pasteboard: pasteboard, activateApp: activateApp,
                 alert: AppAlert(title: "Copié tu respuesta", message: "Pegala cuando arranque la sesión."))
        return .copied
    }

    /// Abre la sesión, trae Hive al frente y deja el texto en el portapapeles con un aviso.
    private static func handOver(_ text: String, sessionId: UUID, store: AppStore, pasteboard: NSPasteboard,
                                 activateApp: (() -> Void)?, alert: AppAlert) {
        HiveNavigator.reveal(store, session: sessionId)
        if let activateApp { activateApp() } else { NSApp?.activate(ignoringOtherApps: true) }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        store.alert = alert
    }
}
