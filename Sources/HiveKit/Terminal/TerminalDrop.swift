import AppKit
import HiveCore
import SwiftTerm

/// Soltar y pegar en la terminal: archivos (su ruta escapada), URLs, texto e imágenes.
enum TerminalDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]

    /// Donde se guardan las imágenes soltadas que no vienen de un archivo (capturas, navegador).
    static var imagesDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("hive-drops", isDirectory: true)
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func webURL(in pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        return urls?.first { !$0.isFileURL }
    }

    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// La imagen del portapapeles en PNG.
    static func pngData(in pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) else { return nil }
        return image.representation(using: .png, properties: [:])
    }

    /// Guarda la imagen como `<carpeta>/<uuid>.png` y devuelve la ruta.
    static func saveImage(_ png: Data, in directory: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(UUID().uuidString).png")
            try png.write(to: file)
            return file.path
        } catch {
            return nil
        }
    }

    /// Si vale la pena aceptar lo que se está arrastrando.
    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: types) != nil
    }

    /// Lo que se pega al soltar algo: archivos → sus rutas escapadas; una imagen sin archivo → se
    /// guarda y se pega su ruta; una URL; o el texto. Nil si no hay nada que sirva.
    static func dropText(from pasteboard: NSPasteboard, imagesDirectory: URL = TerminalDrop.imagesDirectory) -> String? {
        let files = fileURLs(in: pasteboard)
        if !files.isEmpty { return ShellQuoting.pasteText(for: files.map(\.path)) }
        let text = pasteboard.string(forType: .string)
        let url = webURL(in: pasteboard)
        // Una imagen del navegador viene con su URL; un texto con formato puede traer una imagen
        // de cómo se ve, y ahí gana el texto.
        if text == nil || url != nil, let png = pngData(in: pasteboard), let path = saveImage(png, in: imagesDirectory) {
            return ShellQuoting.pasteText(for: [path])
        }
        if let url { return url.absoluteString }
        if let text, !text.isEmpty { return text }
        return nil
    }

    enum PasteAction: Equatable {
        /// Pegar este texto (las rutas de los archivos copiados en Finder).
        case text(String)
        /// Mandar Ctrl+V: Claude y Codex leen la imagen del portapapeles y la adjuntan.
        case controlV
        /// Lo de siempre: SwiftTerm pega el texto.
        case standard
    }

    /// Qué hace ⌘V con este portapapeles.
    static func pasteAction(for pasteboard: NSPasteboard, isAgent: Bool) -> PasteAction {
        let files = fileURLs(in: pasteboard)
        if !files.isEmpty { return .text(ShellQuoting.pasteText(for: files.map(\.path))) }
        if isAgent, pasteboard.string(forType: .string) == nil, hasImage(pasteboard) { return .controlV }
        return .standard
    }
}

extension HiveTerminalView {
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard TerminalDrop.canAccept(sender.draggingPasteboard) else { return [] }
        isDropTarget = true
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTarget ? .copy : []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard drop(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        return true
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    /// Pega lo que se soltó. Devuelve si había algo para pegar.
    @discardableResult
    func drop(from pasteboard: NSPasteboard, imagesDirectory: URL = TerminalDrop.imagesDirectory) -> Bool {
        guard let text = TerminalDrop.dropText(from: pasteboard, imagesDirectory: imagesDirectory) else { return false }
        pastingAsUser { pasteText(text) }
        return true
    }

    /// Lo que ⌘V hace distinto de SwiftTerm: los archivos copiados en Finder pegan su ruta y una
    /// imagen sola, en un agente, le manda Ctrl+V para que la adjunte. Devuelve si se encargó.
    @discardableResult
    func pasteSpecial(from pasteboard: NSPasteboard) -> Bool {
        switch TerminalDrop.pasteAction(for: pasteboard, isAgent: preservesScrollbackOnClear) {
        case .text(let text):
            pastingAsUser { pasteText(text) }
            return true
        case .controlV:
            send([0x16])
            return true
        case .standard:
            return false
        }
    }

    func updateDropHighlight() {
        guard isDropTarget else {
            dropHighlightLayer?.removeFromSuperlayer()
            dropHighlightLayer = nil
            return
        }
        wantsLayer = true
        let highlight = dropHighlightLayer ?? CALayer()
        highlight.frame = bounds
        highlight.borderWidth = 2
        highlight.cornerRadius = 4
        highlight.borderColor = caretColor.cgColor
        highlight.backgroundColor = caretColor.withAlphaComponent(0.06).cgColor
        highlight.zPosition = 1_000
        if highlight.superlayer == nil { layer?.addSublayer(highlight) }
        dropHighlightLayer = highlight
    }
}
