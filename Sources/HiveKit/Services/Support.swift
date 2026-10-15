import AppKit
import Foundation
import HiveCore

struct ExternalApp: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

/// Editores y terminales instalados, para "Abrir en…".
enum ExternalApps {
    private static let editorIDs = [
        ("com.microsoft.VSCode", "VS Code"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("dev.zed.Zed", "Zed"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.apple.dt.Xcode", "Xcode"),
    ]
    private static let terminalIDs = [
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.apple.Terminal", "Terminal"),
    ]

    static let editors = resolve(editorIDs)
    static let terminals = resolve(terminalIDs)

    private static func resolve(_ ids: [(String, String)]) -> [ExternalApp] {
        ids.compactMap { id, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { ExternalApp(id: id, name: name, url: $0) }
        }
    }

    static func open(_ path: String, with app: ExternalApp) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openInEditor(_ path: String) {
        if let editor = editors.first { open(path, with: editor) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func icon(_ app: ExternalApp) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Un archivo de imagen que sirve como ícono (cuadrado o casi, de al menos 16 px).
func isUsableLogo(_ path: String) -> Bool {
    guard let image = NSImage(contentsOfFile: path), image.isValid else { return false }
    let pixels = image.representations.map { CGFloat(max($0.pixelsWide, $0.pixelsHigh)) }.max() ?? 0
    let side = max(pixels, max(image.size.width, image.size.height))
    let ratio = image.size.width / max(image.size.height, 1)
    return side >= 16 && ratio > 0.6 && ratio < 1.67
}
