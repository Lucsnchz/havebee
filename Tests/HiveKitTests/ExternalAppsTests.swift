import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Editores y apps externas")
struct ExternalAppsTests {
    /// Apps "instaladas" de mentira: ninguna búsqueda toca el sistema.
    let fakeLookup: ExternalApps.Lookup = { id in
        ["com.microsoft.VSCode", "com.jetbrains.PhpStorm", "com.google.android.studio", "com.apple.dt.Xcode", "com.mitchellh.ghostty"]
            .contains(id) ? URL(fileURLWithPath: "/Applications/\(id).app") : nil
    }

    var editors: [ExternalApp] { ExternalApps.installed(ExternalApps.editorIDs, lookup: fakeLookup) }

    func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "hive-editors-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test("Suma PhpStorm, Android Studio e IntelliJ; solo lista lo instalado, en orden")
    func list() {
        let ids = ExternalApps.editorIDs.map(\.0)
        #expect(ids.contains("com.jetbrains.PhpStorm") && ids.contains("com.google.android.studio") && ids.contains("com.jetbrains.intellij"))
        #expect(editors.map(\.name) == ["VS Code", "PhpStorm", "Android Studio", "Xcode"])
        #expect(ExternalApps.installed(ExternalApps.terminalIDs, lookup: fakeLookup).map(\.name) == ["Ghostty"])
    }

    @Test("Android con gradlew → Android Studio; Package.swift o .xcodeproj → Xcode")
    func byProject() {
        let dir = TempDir("hive-editors")
        let android = dir.subdir("android").path
        FileManager.default.createFile(atPath: android + "/gradlew", contents: Data())
        let swiftPackage = dir.subdir("paquete").path
        FileManager.default.createFile(atPath: swiftPackage + "/Package.swift", contents: Data())
        let xcode = dir.subdir("app").path
        _ = dir.subdir("app/Hive.xcodeproj")
        let laravel = dir.subdir("laravel").path
        FileManager.default.createFile(atPath: laravel + "/artisan", contents: Data())
        withDefaults { defaults in
            #expect(ExternalApps.preferredEditor(for: android, installed: editors, defaults: defaults)?.name == "Android Studio")
            #expect(ExternalApps.preferredEditor(for: swiftPackage, installed: editors, defaults: defaults)?.name == "Xcode")
            #expect(ExternalApps.preferredEditor(for: xcode, installed: editors, defaults: defaults)?.name == "Xcode")
            #expect(ExternalApps.preferredEditor(for: laravel, installed: editors, defaults: defaults)?.name == "VS Code")
        }
    }

    @Test("Si no, el elegido en Ajustes (si está instalado) o el primero")
    func chosen() {
        let dir = TempDir("hive-editors")
        withDefaults { defaults in
            defaults.set("com.jetbrains.PhpStorm", forKey: "preferredEditor")
            #expect(ExternalApps.preferredEditor(for: dir.path, installed: editors, defaults: defaults)?.name == "PhpStorm")
            defaults.set("dev.zed.Zed", forKey: "preferredEditor") // no instalado
            #expect(ExternalApps.preferredEditor(for: dir.path, installed: editors, defaults: defaults)?.name == "VS Code")
            #expect(ExternalApps.preferredEditor(for: nil, installed: [], defaults: defaults) == nil)
        }
        // Android Studio sin instalar: con gradlew, cae al elegido.
        let android = dir.subdir("android").path
        FileManager.default.createFile(atPath: android + "/gradlew", contents: Data())
        withDefaults { defaults in
            let withoutStudio = editors.filter { $0.id != "com.google.android.studio" }
            #expect(ExternalApps.preferredEditor(for: android, installed: withoutStudio, defaults: defaults)?.name == "VS Code")
        }
    }

    @Test("URLs para abrir en la línea: VS Code, Cursor, Zed y PhpStorm")
    func lineURLs() {
        let path = "/Users/luciano/Herd/ecommerce/app/Http/Controllers/Mis Pedidos.php"
        let encoded = "/Users/luciano/Herd/ecommerce/app/Http/Controllers/Mis%20Pedidos.php"
        #expect(ExternalApps.editorURL(editorId: ExternalApps.vscodeID, path: path, line: 42, column: 7)?.absoluteString
                == "vscode://file\(encoded):42:7")
        #expect(ExternalApps.editorURL(editorId: ExternalApps.cursorID, path: path, line: 42, column: nil)?.absoluteString
                == "cursor://file\(encoded):42")
        #expect(ExternalApps.editorURL(editorId: ExternalApps.zedID, path: path, line: 3, column: 1)?.absoluteString
                == "zed://file\(encoded):3:1")
        let phpStorm = ExternalApps.editorURL(editorId: ExternalApps.phpStormID, path: path, line: 42, column: nil)
        #expect(phpStorm?.scheme == "phpstorm" && phpStorm?.host == "open")
        let query = URLComponents(url: phpStorm!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "file" }?.value == path)
        #expect(query.first { $0.name == "line" }?.value == "42")
    }

    @Test("Sin línea, o con un editor sin URL (Xcode, Android Studio), se abre con la app")
    func noURL() {
        #expect(ExternalApps.editorURL(editorId: ExternalApps.vscodeID, path: "/tmp/a.php", line: nil, column: nil) == nil)
        #expect(ExternalApps.editorURL(editorId: ExternalApps.xcodeID, path: "/tmp/a.swift", line: 3, column: nil) == nil)
        #expect(ExternalApps.editorURL(editorId: ExternalApps.androidStudioID, path: "/tmp/a.kt", line: 3, column: nil) == nil)
    }
}
