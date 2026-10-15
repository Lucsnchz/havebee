import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Un portapapeles propio (nunca el general del usuario) que se libera al terminar.
private final class ScratchPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("hive-drop-\(UUID().uuidString)"))
    deinit { board.releaseGlobally() }
}

/// Una imagen PNG chiquita.
private func tinyPNG() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.setColor(.red, atX: 0, y: 0)
    return rep.representation(using: .png, properties: [:])!
}

@MainActor
@Suite("Soltar, pegar, enlaces y menú de la terminal", .serialized)
struct TerminalDropTests {
    final class Typed {
        var bytes: [UInt8] = []
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    func makeTerminal(agent: Bool) -> (HiveTerminalView, Typed) {
        _ = NSApplication.shared
        let view = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), scrollback: 1_000)
        view.preservesScrollbackOnClear = agent
        let typed = Typed()
        view.onUserInput = { typed.bytes += $0 }
        return (view, typed)
    }

    @Test("Soltar un archivo con espacios y ñ pega su ruta escapada, con un espacio al final")
    func dropFile() async throws {
        let dir = TempDir("hive-drop")
        let file = dir.write("Mis Documentos/año 2026.png", "x")
        let paste = ScratchPasteboard()
        paste.board.clearContents()
        paste.board.writeObjects([file as NSURL])
        let (view, typed) = makeTerminal(agent: true)
        #expect(view.drop(from: paste.board))
        #expect(await waitUntil { typed.text == "'\(file.path)' " })
    }

    @Test("Soltar varios archivos: todas las rutas, separadas por espacios")
    func dropFiles() async {
        let dir = TempDir("hive-drop")
        let a = dir.write("a.txt"), b = dir.write("con espacio.txt")
        let paste = ScratchPasteboard()
        paste.board.clearContents()
        paste.board.writeObjects([a as NSURL, b as NSURL])
        let (view, typed) = makeTerminal(agent: false)
        view.drop(from: paste.board)
        #expect(await waitUntil { typed.text == "\(a.path) '\(b.path)' " })
    }

    @Test("Soltar una imagen sin archivo la guarda como PNG y pega su ruta")
    func dropImage() async throws {
        let dir = TempDir("hive-drop-images")
        let paste = ScratchPasteboard()
        paste.board.clearContents()
        paste.board.setData(tinyPNG(), forType: .png)
        let (view, typed) = makeTerminal(agent: true)
        #expect(view.drop(from: paste.board, imagesDirectory: dir.url))
        #expect(await waitUntil { typed.text.hasSuffix(" ") })
        let path = typed.text.trimmingCharacters(in: .whitespaces)
        #expect(path.hasPrefix(dir.path) && path.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Soltar una URL o texto los pega tal cual")
    func dropURLAndText() async {
        let paste = ScratchPasteboard()
        paste.board.clearContents()
        paste.board.writeObjects([URL(string: "https://bevo.test/admin")! as NSURL])
        let (view, typed) = makeTerminal(agent: false)
        view.drop(from: paste.board)
        #expect(await waitUntil { typed.text == "https://bevo.test/admin" })

        paste.board.clearContents()
        paste.board.setString("php artisan test", forType: .string)
        typed.bytes = []
        view.drop(from: paste.board)
        #expect(await waitUntil { typed.text == "php artisan test" })
    }

    @Test("⌘V con solo una imagen: Ctrl+V en un agente; en una terminal, lo de siempre")
    func pasteImage() {
        let paste = ScratchPasteboard()
        paste.board.clearContents()
        paste.board.setData(tinyPNG(), forType: .png)
        let (agent, agentTyped) = makeTerminal(agent: true)
        #expect(agent.pasteSpecial(from: paste.board))
        #expect(agentTyped.bytes == [0x16])

        let (shell, shellTyped) = makeTerminal(agent: false)
        #expect(!shell.pasteSpecial(from: paste.board))
        #expect(shellTyped.bytes.isEmpty)
    }

    @Test("⌘V con archivos copiados en Finder pega sus rutas; con texto, lo pega SwiftTerm")
    func pasteFiles() async {
        let dir = TempDir("hive-drop")
        let file = dir.write("informe final.pdf")
        let paste = ScratchPasteboard()
        paste.board.clearContents()
        paste.board.writeObjects([file as NSURL])
        let (view, typed) = makeTerminal(agent: true)
        #expect(view.pasteSpecial(from: paste.board))
        #expect(await waitUntil { typed.text == "'\(file.path)' " })

        paste.board.clearContents()
        paste.board.setString("hola", forType: .string)
        #expect(!view.pasteSpecial(from: paste.board))
    }

    @Test("⌘clic en «app/Http/Controllers/X.php:42» abre el archivo en la línea 42 (carpeta de OSC 7)")
    func openLink() {
        let dir = TempDir("hive-link")
        dir.write("app/Http/Controllers/X.php", "<?php\n")
        let (view, _) = makeTerminal(agent: true)
        view.hostCurrentDirectoryUpdate(source: view, directory: URL(fileURLWithPath: dir.path).absoluteString)
        #expect(view.workingDirectory == dir.path)
        var opened: [TerminalLink.Target] = []
        view.openLinkTarget = { opened.append($0) }
        view.requestOpenLink(source: view, link: "app/Http/Controllers/X.php:42", params: [:])
        view.requestOpenLink(source: view, link: "https://laravel.com/docs", params: [:])
        #expect(opened == [.file(path: dir.path + "/app/Http/Controllers/X.php", line: 42, column: nil),
                           .url(URL(string: "https://laravel.com/docs")!)])
    }

    @Test("Menú del clic derecho: en castellano, sin Limpiar en los agentes y con el enlace de abajo del mouse")
    func contextMenu() throws {
        let dir = TempDir("hive-menu")
        dir.write("README.md", "# Hola\n")
        let (agent, _) = makeTerminal(agent: true)
        agent.hostCurrentDirectoryUpdate(source: agent, directory: dir.path)
        agent.receive(Array("README.md:3 tiene el detalle".utf8)[...])
        // Arriba a la izquierda: la primera fila, donde está el enlace.
        let topLeft = NSPoint(x: 2, y: agent.bounds.height - 2)
        let titles = TerminalContextMenu.menu(for: agent, at: topLeft).items.map(\.title).filter { !$0.isEmpty }
        #expect(titles == ["Copiar", "Pegar", "Seleccionar todo", "Buscar…", "Abrir enlace", "Copiar enlace",
                           "Mostrar carpeta en Finder", "Agrandar texto", "Achicar texto"])
        let link = try #require(TerminalContextMenu.link(in: agent, at: topLeft))
        #expect(link.target == .file(path: dir.path + "/README.md", line: 3, column: nil))
        #expect(TerminalContextMenu.copyText(for: link.target) == dir.path + "/README.md:3")

        let (shell, _) = makeTerminal(agent: false)
        let shellTitles = TerminalContextMenu.menu(for: shell, at: .zero).items.map(\.title)
        #expect(shellTitles.contains("Limpiar"))
        #expect(!shellTitles.contains("Abrir enlace"))
        #expect(shell.validateUserInterfaceItem(NSMenuItem(title: "Limpiar", action: #selector(HiveTerminalView.clearTerminal(_:)), keyEquivalent: "")))
        let agentClear = NSMenuItem(title: "Limpiar", action: #selector(HiveTerminalView.clearTerminal(_:)), keyEquivalent: "")
        #expect(!agent.validateUserInterfaceItem(agentClear))
        #expect(agentClear.toolTip == "Usá /clear: el historial sigue en el panel")
    }

    @Test("Si el programa usa el mouse, el clic derecho es suyo")
    func mouseModeMenu() {
        let (view, _) = makeTerminal(agent: false)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(view.menu(for: event) != nil)
        view.receive(Array("\u{1B}[?1000h".utf8)[...])
        #expect(view.menu(for: event) == nil)
    }

    @Test("Limpiar borra pantalla y scroll en una terminal y le manda Ctrl+L")
    func clear() {
        let (view, typed) = makeTerminal(agent: false)
        view.receive(Array("línea vieja\r\n".utf8)[...])
        view.clearTerminal(nil)
        #expect(!view.fullText().contains("línea vieja"))
        #expect(typed.bytes == [0x0C])

        let (agent, agentTyped) = makeTerminal(agent: true)
        agent.receive(Array("charla\r\n".utf8)[...])
        agent.clearTerminal(nil)
        #expect(agent.fullText().contains("charla"))
        #expect(agentTyped.bytes.isEmpty)
    }

    @Test("Agrandar y achicar texto cambian el ajuste de todas las terminales")
    func zoom() {
        let name = "hive-zoom-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (view, _) = makeTerminal(agent: false)
        TerminalTheme.apply(to: view, defaults: defaults)
        view.biggerText(nil)
        #expect(defaults.double(forKey: "terminalFontSize") == 14)
        view.smallerText(nil)
        view.smallerText(nil)
        #expect(defaults.double(forKey: "terminalFontSize") == 12)
    }
}
