import AppKit
import HiveCore
import SwiftTerm

/// Avisos de la terminal hacia quien la usa (sesión o comando).
@MainActor
protocol HiveTerminalDelegate: AnyObject {
    func terminalTitleChanged(_ terminal: HiveTerminalView, title: String)
    func terminalProcessTerminated(_ terminal: HiveTerminalView, exitCode: Int32?)
}

/// Terminal de Hive: una vista de SwiftTerm con su propio proceso. Manejamos el proceso nosotros
/// (en lugar de `LocalProcessTerminalView`) para ver cada byte antes de dibujarlo y poder
/// conservar lo anterior cuando un agente limpia la pantalla con /clear.
public final class HiveTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
    private var process: LocalProcess!
    weak var processDelegate: HiveTerminalDelegate?
    /// Lo que escribe el usuario (teclado, pegar, soltar). No incluye las respuestas automáticas.
    /// Lo pegado avisa un instante después de mandarlo (ver `deliverFromTerminal`).
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    /// Todo lo que le llega al proceso, también las respuestas automáticas (para las pruebas).
    var onProcessInput: ((ArraySlice<UInt8>) -> Void)?
    private var onOutput: (() -> Void)?

    /// Si un agente borra pantalla y scroll justo después de un Enter (como /clear), en vez de
    /// perder todo dejamos la pantalla en el scroll con una línea divisoria. Lo activa el store
    /// en las sesiones de agente, así que también dice si la terminal es de un agente.
    var preservesScrollbackOnClear = false
    private var preserver = ClearPreserver()
    /// Reloj inyectable para las pruebas.
    var now: () -> Date = Date.init

    /// Carpeta donde arrancó el proceso, y la que avisó el shell después con OSC 7.
    private(set) var startDirectory: String?
    private(set) var reportedDirectory: String?
    /// Contra qué carpeta se resuelven los enlaces relativos.
    var workingDirectory: String? { reportedDirectory ?? startDirectory }
    /// Qué hacer con un enlace resuelto (⌘clic o «Abrir enlace»). Por defecto, abrirlo.
    var openLinkTarget: ((TerminalLink.Target) -> Void)?

    /// De dónde lee sus ajustes y cuáles aplicó la última vez (los pone `TerminalTheme.apply`).
    private(set) var preferencesDefaults: UserDefaults = .standard
    private(set) var appliedPreferences: TerminalPreferences?
    private var appliedLightPalette: Bool?
    private var defaultsObserver: TerminalDefaultsObserver?

    /// Mientras arrastran algo encima, el borde se pinta con el color del cursor.
    var isDropTarget = false {
        didSet { updateDropHighlight() }
    }
    var dropHighlightLayer: CALayer?
    private var isPastingAsUser = false

    /// `scrollback`: cuántas líneas se guardan para volver con el scroll (SwiftTerm trae 500).
    init(frame: NSRect, scrollback: Int) {
        super.init(frame: frame, font: nil, options: TerminalOptions(scrollback: scrollback))
        terminalDelegate = self
        process = LocalProcess(delegate: self, dispatchQueue: .main)
        // La campana destella; si la terminal no se ve, además pide atención (sin sonido).
        bellStyle = .soundAndVisual
        registerForDraggedTypes(TerminalDrop.types)
        TerminalKeyMonitor.install()
    }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, scrollback: 10_000)
    }

    required init?(coder: NSCoder) { fatalError("No se usa desde storyboards") }

    func startProcess(executable: String, args: [String], environment: [String], currentDirectory: String) {
        startDirectory = currentDirectory
        reportedDirectory = nil
        process.startProcess(executable: executable, args: args, environment: environment, currentDirectory: currentDirectory)
    }

    func terminate() { process.terminate() }

    /// Lo usan el menú de la sesión, el dock y los paneles.
    var isProcessRunning: Bool { process.running }

    func setProcessOutputHandler(_ handler: @escaping () -> Void) { onOutput = handler }

    /// Todo el texto de la terminal, con el scroll incluido (para copiar o guardar).
    func fullText() -> String {
        selectAll(nil)
        defer { selectNone() }
        return getSelection() ?? ""
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // El margen del contenedor toma el fondo de la terminal (oscuro o claro).
        superview?.layer?.backgroundColor = nativeBackgroundColor.cgColor
    }

    // MARK: - Teclado

    /// Lo que Hive hace distinto de SwiftTerm con una tecla. Devuelve si se encargó. SwiftTerm no
    /// deja sobrescribir `keyDown` (no es `open`), así que esto lo llama un monitor de teclado de
    /// la app (`TerminalKeyMonitor`) antes de que la tecla le llegue a la terminal.
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control) else { return false }

        // Shift+Enter y ⌥Enter en un agente: salto de línea en el prompt (ESC CR en un solo envío).
        if preservesScrollbackOnClear,
           event.keyCode == TerminalKeys.Code.returnKey || event.keyCode == TerminalKeys.Code.keypadEnter,
           let bytes = TerminalKeys.modifiedReturn(shift: flags.contains(.shift), option: flags.contains(.option),
                                                   kittyActive: !keyboardEnhancementFlags.isEmpty) {
            send(bytes)
            return true
        }

        guard flags.contains(.option), optionKey == .characters else { return false }
        if let bytes = TerminalKeys.optionWordJump(keyCode: event.keyCode, shift: flags.contains(.shift),
                                                   kittyActive: !keyboardEnhancementFlags.isEmpty) {
            // ⌥← y ⌥→ saltan de a palabras (ESC b / ESC f, como Meta en Terminal.app e iTerm).
            send(bytes)
            return true
        }
        if event.keyCode == TerminalKeys.Code.space {
            // ⌥Espacio escribe un espacio común (no el espacio duro que rompe los comandos).
            send([0x20])
            return true
        }
        guard TerminalKeys.optionShouldCompose(keyCode: event.keyCode) else { return false }
        // Que macOS arme el carácter (ñ, á, @, [, |…) en lugar de mandar ESC y la tecla.
        let wasMeta = optionAsMetaKey
        optionAsMetaKey = false
        defer { optionAsMetaKey = wasMeta }
        keyDown(with: event)
        return true
    }

    /// Una tecla como si llegara del teclado: primero lo de Hive y, si no, SwiftTerm.
    func processKeyEvent(_ event: NSEvent) {
        if !handleKeyDown(event) { keyDown(with: event) }
    }

    /// Qué hace ⌥ según los ajustes.
    private var optionKey: TerminalPreferences.OptionKey {
        (appliedPreferences ?? TerminalPreferences.read(preferencesDefaults)).optionKey
    }

    // MARK: - Pegar

    /// ⌘V: los archivos copiados en Finder pegan su ruta y una imagen sola, en un agente, se
    /// adjunta con Ctrl+V (ver `pasteSpecial`). Lo demás lo pega SwiftTerm.
    public override func paste(_ sender: Any) {
        pastingAsUser {
            if !pasteSpecial(from: NSPasteboard.general) { super.paste(sender) }
        }
    }

    // MARK: - Limpiar

    /// Borra la pantalla y el scroll y le manda Ctrl+L al proceso para que redibuje su prompt.
    /// En los agentes no se usa: el historial queda en el panel y ahí se limpia con /clear.
    @objc func clearTerminal(_ sender: Any?) {
        guard !preservesScrollbackOnClear else {
            NSSound.beep()
            return
        }
        feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        sendInput([0x0C])
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(clearTerminal(_:)):
            if preservesScrollbackOnClear {
                (item as? NSMenuItem)?.toolTip = "Usá /clear: el historial sigue en el panel"
                return false
            }
            return true
        case #selector(openLinkFromMenu(_:)), #selector(copyLinkFromMenu(_:)), #selector(revealDirectoryFromMenu(_:)),
             #selector(biggerText(_:)), #selector(smallerText(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: - Menú contextual

    public override func menu(for event: NSEvent) -> NSMenu? {
        // Si el programa usa el mouse (vim, htop), el clic derecho es suyo.
        guard currentMouseMode == .off else { return nil }
        return TerminalContextMenu.menu(for: self, at: event.locationInWindow)
    }

    // MARK: - Apariencia

    /// Lo llama `TerminalTheme.apply`: desde ahí la terminal sigue sola los cambios de ajustes.
    func preferencesApplied(_ prefs: TerminalPreferences, from defaults: UserDefaults) {
        appliedPreferences = prefs
        preferencesDefaults = defaults
        appliedLightPalette = prefs.usesLightPalette(for: effectiveAppearance)
        if defaultsObserver == nil {
            defaultsObserver = TerminalDefaultsObserver { [weak self] in self?.reapplyPreferences() }
        }
    }

    /// Vuelve a leer los ajustes y aplica lo que cambió. No toca el color del cursor (es el del
    /// proyecto) y conserva la diferencia entre su letra y la preferencia (la esquinita de
    /// comandos va un punto más chica).
    func reapplyPreferences() {
        guard let previous = appliedPreferences else { return }
        let prefs = TerminalPreferences.read(preferencesDefaults)
        if prefs.fontSize != previous.fontSize || prefs.fontName != previous.fontName {
            let delta = Double(font.pointSize) - previous.fontSize
            let size = max(6, prefs.fontSize + delta)
            font = prefs.font(size: CGFloat(size))
        }
        if prefs.cursor != previous.cursor {
            setCursorStyle(prefs.cursor.style)
        }
        appliedPreferences = prefs
        applyPaletteIfNeeded()
    }

    private func applyPaletteIfNeeded() {
        guard let prefs = appliedPreferences else { return }
        let light = prefs.usesLightPalette(for: effectiveAppearance)
        guard light != appliedLightPalette else { return }
        appliedLightPalette = light
        TerminalTheme.applyColors(light ? .light : .dark, to: self)
        updateDropHighlight()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPaletteIfNeeded()
    }

    // MARK: - LocalProcessDelegate (llega por la cola principal)

    nonisolated public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated {
            processDelegate?.terminalProcessTerminated(self, exitCode: exitCode)
        }
    }

    /// El proceso no llegó a arrancar (por ejemplo, la carpeta no existe): se avisa como si
    /// hubiera terminado, así la sesión no queda «corriendo» sin proceso.
    nonisolated public func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        let report = { @MainActor [weak self] in
            guard let self else { return }
            self.feed(text: "\r\n  No se pudo abrir el proceso: \(error)\r\n")
            self.processDelegate?.terminalProcessTerminated(self, exitCode: nil)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { report() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { report() } }
        }
    }

    nonisolated public func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { receive(slice) }
    }

    nonisolated public func getWindowSize() -> winsize {
        let dimensions = terminalDimensions
        return winsize(ws_row: UInt16(dimensions.rows), ws_col: UInt16(dimensions.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    /// Salida del proceso (pasa por el filtro de /clear si corresponde).
    func receive(_ slice: ArraySlice<UInt8>) {
        onOutput?()
        guard preservesScrollbackOnClear else {
            feed(byteArray: slice)
            return
        }
        let dimensions = terminalDimensions
        feed(byteArray: preserver.process(slice, now: now(), rows: dimensions.rows, cols: dimensions.cols)[...])
    }

    // MARK: - Respuestas automáticas

    /// Las respuestas de la terminal a las consultas del programa (posición del cursor, DA1,
    /// color de fondo, versión, flags de kitty) van directo al proceso: no son tipeo, así que no
    /// pasan por `onUserInput` (no marcan la sesión como vista ni «trabajando») ni por el filtro
    /// de /clear. Por acá también sale lo que se pega; eso sí es del usuario (ver `pastingAsUser`).
    nonisolated public override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliverFromTerminal(bytes[...]) }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.deliverFromTerminal(bytes[...]) }
            }
        }
    }

    private func deliverFromTerminal(_ data: ArraySlice<UInt8>) {
        guard isPastingAsUser else {
            writeToProcess(data)
            return
        }
        // Lo pegado sale de SwiftTerm con su lock tomado (no es recursivo: si quien escucha
        // `onUserInput` consulta la terminal, la app se cae). Se escribe ya, así ninguna tecla
        // se le adelanta, y el aviso de que el usuario escribió va un instante después, sin el lock.
        if TerminalInput.isSubmit(data) { preserver.userPressedEnter(at: now()) }
        writeToProcess(data)
        let bytes = Array(data)
        DispatchQueue.main.async { [weak self] in
            self?.onUserInput?(bytes[...])
        }
    }

    /// Mientras corre `body`, lo que SwiftTerm mande por el camino de las respuestas es un pegado
    /// del usuario (⌘V o soltar algo) y pasa por `onUserInput` como lo tipeado.
    func pastingAsUser(_ body: () -> Void) {
        let previous = isPastingAsUser
        isPastingAsUser = true
        defer { isPastingAsUser = previous }
        body()
    }

    private func writeToProcess(_ data: ArraySlice<UInt8>) {
        onProcessInput?(data)
        process.send(data: data)
    }

    // MARK: - TerminalViewDelegate

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        var size = getWindowSize()
        _ = process.updateWindowSize(&size)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.terminalTitleChanged(self, title: title)
    }

    /// OSC 7: el shell avisa en qué carpeta está (para resolver los enlaces relativos).
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let path = TerminalLink.directory(fromOSC7: directory) { reportedDirectory = path }
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendInput(data)
    }

    /// Entrada del usuario hacia el proceso.
    func sendInput(_ data: ArraySlice<UInt8>) {
        // Solo un Enter que manda cuenta para /clear: no ESC CR (Shift+Enter) ni lo pegado.
        if TerminalInput.isSubmit(data) { preserver.userPressedEnter(at: now()) }
        onUserInput?(data)
        writeToProcess(data)
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52: los programas pueden copiar al portapapeles. Leerlo no: queda el nil por defecto
    /// de SwiftTerm, que niega el pedido (si no, cualquier script se llevaría lo que copiaste).
    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘clic en un enlace: URLs al navegador, archivos al editor en su línea, carpetas a Finder.
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let target = TerminalLink.resolve(link, cwd: workingDirectory, home: NSHomeDirectory()) else {
            NSSound.beep()
            return
        }
        open(target)
    }

    func open(_ target: TerminalLink.Target) {
        if let openLinkTarget {
            openLinkTarget(target)
            return
        }
        switch target {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .folder(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        case .file(let path, let line, let column):
            // El proyecto se busca desde el archivo: puede estar fuera de la carpeta de la sesión.
            ExternalApps.openFile(path, line: line, column: column)
        }
    }

    /// La campana: SwiftTerm ya destella (bellStyle = .soundAndVisual). Si la terminal no está a
    /// la vista, además rebota el ícono del Dock, sin sonido.
    public func bell(source: TerminalView) {
        guard let window, window.isVisible, window.isMainWindow, NSApp?.isActive == true else {
            NSApp?.requestUserAttention(.informationalRequest)
            return
        }
    }
}

/// Le pasa a la terminal con el foco cada tecla antes que nadie, para que `handleKeyDown`
/// decida qué hacer con ⌥ y con Shift+Enter (SwiftTerm no deja sobrescribir `keyDown`).
@MainActor
enum TerminalKeyMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                (event.window?.firstResponder as? HiveTerminalView)?.handleKeyDown(event) ?? false
            }
            return handled ? nil : event
        }
    }
}

/// Avisa cuando cambia algún UserDefaults del proceso. Se da de baja solo al liberarse.
private final class TerminalDefaultsObserver {
    private var token: NSObjectProtocol?

    init(_ onChange: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
