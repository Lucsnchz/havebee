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
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    private var onOutput: (() -> Void)?

    /// Si un agente borra pantalla y scroll justo después de un Enter (como /clear), en vez de
    /// perder todo dejamos la pantalla en el scroll con una línea divisoria.
    var preservesScrollbackOnClear = false
    private var preserver = ClearPreserver()
    /// Reloj inyectable para las pruebas.
    var now: () -> Date = Date.init

    /// `scrollback`: cuántas líneas se guardan para volver con el scroll (SwiftTerm trae 500).
    init(frame: NSRect, scrollback: Int) {
        super.init(frame: frame, font: nil, options: TerminalOptions(scrollback: scrollback))
        terminalDelegate = self
        process = LocalProcess(delegate: self, dispatchQueue: .main)
    }

    override convenience init(frame: NSRect) {
        self.init(frame: frame, scrollback: 10_000)
    }

    required init?(coder: NSCoder) { fatalError("No se usa desde storyboards") }

    func startProcess(executable: String, args: [String], environment: [String], currentDirectory: String) {
        process.startProcess(executable: executable, args: args, environment: environment, currentDirectory: currentDirectory)
    }

    func terminate() { process.terminate() }

    var isProcessRunning: Bool { process.running }

    func setProcessOutputHandler(_ handler: @escaping () -> Void) { onOutput = handler }

    /// Todo el texto de la terminal, con el scroll incluido.
    func fullText() -> String {
        selectAll(nil)
        defer { selectNone() }
        return getSelection() ?? ""
    }

    // MARK: LocalProcessDelegate (llega por la cola principal)

    nonisolated public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated {
            processDelegate?.terminalProcessTerminated(self, exitCode: exitCode)
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

    // MARK: TerminalViewDelegate

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        var size = getWindowSize()
        _ = process.updateWindowSize(&size)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.terminalTitleChanged(self, title: title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendInput(data)
    }

    /// Entrada del usuario hacia el proceso.
    func sendInput(_ data: ArraySlice<UInt8>) {
        if data.contains(13) { preserver.userPressedEnter(at: now()) }
        onUserInput?(data)
        process.send(data: data)
    }

    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }
}

enum TerminalTheme {
    static let background = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.094, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.87, green: 0.87, blue: 0.89, alpha: 1)

    private static let palette: [(UInt16, UInt16, UInt16)] = [
        (0x2A, 0x2B, 0x33), (0xF0, 0x71, 0x78), (0x9F, 0xD1, 0x8B), (0xF5, 0xC2, 0x6B),
        (0x7A, 0xA7, 0xF5), (0xC6, 0x9C, 0xF0), (0x6F, 0xCF, 0xD1), (0xD4, 0xD4, 0xD8),
        (0x5E, 0x60, 0x6E), (0xFF, 0x8E, 0x94), (0xB8, 0xE6, 0xA3), (0xFF, 0xD8, 0x8C),
        (0x9C, 0xC1, 0xFF), (0xDB, 0xB8, 0xFF), (0x93, 0xE5, 0xE6), (0xF5, 0xF5, 0xF7),
    ]

    @MainActor
    static func apply(to view: TerminalView) {
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 1)
        view.selectedTextBackgroundColor = NSColor(srgbRed: 0.24, green: 0.30, blue: 0.42, alpha: 1)
        view.installColors(palette.map { SwiftTerm.Color(red8: $0.0, green8: $0.1, blue8: $0.2) })
        view.optionAsMetaKey = true
    }
}
