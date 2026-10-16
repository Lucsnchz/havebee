import AppKit
import HiveCore
import SwiftTerm

/// Menú del clic derecho en la terminal.
enum TerminalContextMenu {
    /// El menú para un clic en `windowPoint` (coordenadas de la ventana).
    @MainActor
    static func menu(for view: HiveTerminalView, at windowPoint: NSPoint) -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = true
        func add(_ title: String, _ action: Selector, tag: Int = 0, object: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = view
            item.tag = tag
            item.representedObject = object
            menu.addItem(item)
        }

        add("Copiar", #selector(TerminalView.copy(_:)))
        add("Pegar", #selector(TerminalView.paste(_:)))
        add("Seleccionar todo", #selector(NSResponder.selectAll(_:)))
        add("Buscar…", #selector(NSResponder.performTextFinderAction(_:)), tag: NSTextFinder.Action.showFindInterface.rawValue)
        if !view.preservesScrollbackOnClear {
            add("Limpiar", #selector(HiveTerminalView.clearTerminal(_:)))
        }

        if let link = link(in: view, at: windowPoint) {
            menu.addItem(.separator())
            add("Abrir enlace", #selector(HiveTerminalView.openLinkFromMenu(_:)), object: link.text)
            add("Copiar enlace", #selector(HiveTerminalView.copyLinkFromMenu(_:)), object: link.text)
        }
        if view.workingDirectory != nil {
            menu.addItem(.separator())
            add("Mostrar carpeta en Finder", #selector(HiveTerminalView.revealDirectoryFromMenu(_:)))
        }
        menu.addItem(.separator())
        add("Agrandar texto", #selector(HiveTerminalView.biggerText(_:)))
        add("Achicar texto", #selector(HiveTerminalView.smallerText(_:)))
        return menu
    }

    /// El enlace que hay bajo el punto, si hay alguno que se pueda abrir.
    @MainActor
    static func link(in view: HiveTerminalView, at windowPoint: NSPoint) -> (text: String, target: TerminalLink.Target)? {
        let cols = view.terminalDimensions.cols
        let index = view.characterIndex(for: windowPoint)
        guard cols > 0, index >= 0 else { return nil }
        let row = index / cols
        let column = index % cols
        guard let line = view.visibleRowsText(row..<(row + 1)).first,
              let word = TerminalLink.candidate(in: line, at: column),
              let target = TerminalLink.resolve(word, cwd: view.workingDirectory, home: NSHomeDirectory()) else { return nil }
        return (word, target)
    }

    /// Lo que se copia de un enlace: la URL, o la ruta completa (con la línea si la tiene).
    static func copyText(for target: TerminalLink.Target) -> String {
        switch target {
        case .url(let url): url.absoluteString
        case .folder(let path): path
        case .file(let path, let line, let column):
            path + (line.map { ":\($0)" } ?? "") + (column.map { ":\($0)" } ?? "")
        }
    }
}

extension HiveTerminalView {
    @objc func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String,
              let target = TerminalLink.resolve(text, cwd: workingDirectory, home: NSHomeDirectory()) else { return }
        open(target)
    }

    @objc func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String,
              let target = TerminalLink.resolve(text, cwd: workingDirectory, home: NSHomeDirectory()) else { return }
        ExternalApps.copyToPasteboard(TerminalContextMenu.copyText(for: target))
    }

    @objc func revealDirectoryFromMenu(_ sender: Any?) {
        guard let directory = workingDirectory else { return }
        HiveTerminalView.showFolder(directory)
    }

    /// Agranda la letra de todas las terminales (es el mismo ajuste que ⌘+).
    @objc func biggerText(_ sender: Any?) { changeFontSize(by: 1) }

    @objc func smallerText(_ sender: Any?) { changeFontSize(by: -1) }

    func changeFontSize(by delta: Double) {
        let current = TerminalPreferences.read(preferencesDefaults).fontSize
        preferencesDefaults.set(TerminalPreferences.clampedSize(current + delta), forKey: TerminalPreferences.fontSizeKey)
    }
}
