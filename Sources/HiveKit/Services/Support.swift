import AppKit
import Foundation
import HiveCore

struct ExternalApp: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

/// Editores y terminales instalados, para "Abrir en…" y para abrir archivos desde la terminal.
enum ExternalApps {
    static let vscodeID = "com.microsoft.VSCode"
    static let cursorID = "com.todesktop.230313mzl4w4u92"
    static let zedID = "dev.zed.Zed"
    static let phpStormID = "com.jetbrains.PhpStorm"
    static let androidStudioID = "com.google.android.studio"
    static let intelliJID = "com.jetbrains.intellij"
    static let xcodeID = "com.apple.dt.Xcode"

    static let editorIDs = [
        (vscodeID, "VS Code"),
        (cursorID, "Cursor"),
        (zedID, "Zed"),
        (phpStormID, "PhpStorm"),
        (androidStudioID, "Android Studio"),
        (intelliJID, "IntelliJ IDEA"),
        ("com.sublimetext.4", "Sublime Text"),
        (xcodeID, "Xcode"),
    ]
    static let terminalIDs = [
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.apple.Terminal", "Terminal"),
    ]

    /// Dónde está instalada una app (nil si no está).
    typealias Lookup = (String) -> URL?
    static let systemLookup: Lookup = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }

    /// Se calculan cada vez: si instalás un editor con Hive abierto, aparece.
    static var editors: [ExternalApp] { installed(editorIDs) }
    static var terminals: [ExternalApp] { installed(terminalIDs) }

    static func installed(_ ids: [(String, String)], lookup: Lookup = systemLookup) -> [ExternalApp] {
        ids.compactMap { id, name in lookup(id).map { ExternalApp(id: id, name: name, url: $0) } }
    }

    /// Editor elegido en Ajustes (bundle id). Vacío: el primero instalado.
    static let preferredEditorKey = "preferredEditor"

    /// El editor para una carpeta: Android Studio si tiene gradlew, Xcode si tiene un .xcodeproj o
    /// Package.swift, y si no el elegido en Ajustes o el primero instalado.
    static func preferredEditor(for dir: String?, installed: [ExternalApp] = editors, defaults: UserDefaults = .standard) -> ExternalApp? {
        func app(_ id: String) -> ExternalApp? { installed.first { $0.id == id } }
        if let dir {
            let files = FileManager.default
            if files.fileExists(atPath: (dir as NSString).appendingPathComponent("gradlew")), let studio = app(androidStudioID) {
                return studio
            }
            let isXcodeProject = files.fileExists(atPath: (dir as NSString).appendingPathComponent("Package.swift"))
                || ((try? files.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.hasSuffix(".xcodeproj") }
            if isXcodeProject, let xcode = app(xcodeID) { return xcode }
        }
        if let id = defaults.string(forKey: preferredEditorKey), let chosen = app(id) { return chosen }
        return installed.first
    }

    /// URL que abre el archivo en esa línea con el editor, si el editor tiene una.
    static func editorURL(editorId: String, path: String, line: Int?, column: Int?) -> URL? {
        guard let line else { return nil }
        let location = ":\(line)" + (column.map { ":\($0)" } ?? "")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        switch editorId {
        case vscodeID: return URL(string: "vscode://file\(encodedPath)\(location)")
        case cursorID: return URL(string: "cursor://file\(encodedPath)\(location)")
        case zedID: return URL(string: "zed://file\(encodedPath)\(location)")
        case phpStormID:
            var components = URLComponents()
            components.scheme = "phpstorm"
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "file", value: path), URLQueryItem(name: "line", value: "\(line)")]
            return components.url
        default: return nil
        }
    }

    /// Abre un archivo en el editor que corresponde, en su línea y columna si se puede.
    static func openFile(_ path: String, line: Int? = nil, column: Int? = nil, projectDirectory: String? = nil) {
        let editor = preferredEditor(for: projectDirectory ?? (path as NSString).deletingLastPathComponent)
        if let editor, let url = editorURL(editorId: editor.id, path: path, line: line, column: column) {
            NSWorkspace.shared.open(url)
        } else if let editor {
            open(path, with: editor)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    static func open(_ path: String, with app: ExternalApp) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Abre un archivo o una carpeta en el editor preferido.
    static func openInEditor(_ path: String) {
        var isDirectory: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        openFile(path, projectDirectory: folder ? path : nil)
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
