import Foundation
import Testing
@testable import HiveKit

/// Un updater de mentira: guarda lo que le piden y deja avisar cuándo cambia `canCheckForUpdates`.
@MainActor
private final class FakeUpdater: AppUpdating {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = true
    var checks = 0
    var onCanCheck: (@MainActor (Bool) -> Void)?

    func checkForUpdates() { checks += 1 }
    func observeCanCheck(_ change: @escaping @MainActor (Bool) -> Void) { onCanCheck = change }
}

@MainActor
@Suite("Actualizaciones")
struct AppUpdatesTests {
    @Test("Sin updater (swift run, tests) no hay nada que mostrar ni que buscar")
    func unavailable() {
        let updates = AppUpdates()
        #expect(!updates.isAvailable)
        #expect(!updates.canCheck)
        updates.checkForUpdates()
        updates.setAutomaticChecks(true)
        #expect(!updates.automaticChecks)
    }

    @Test("Conectado: el menú y los ajustes siguen al updater")
    func connected() {
        let fake = FakeUpdater()
        let updates = AppUpdates()
        updates.connect(fake)
        #expect(updates.isAvailable && updates.canCheck)
        #expect(updates.automaticChecks && updates.automaticDownloads)

        updates.checkForUpdates()
        #expect(fake.checks == 1)
        // Mientras busca o instala, «Buscar actualizaciones…» queda apagado.
        fake.onCanCheck?(false)
        #expect(!updates.canCheck)
        fake.onCanCheck?(true)
        #expect(updates.canCheck)

        updates.setAutomaticDownloads(false)
        #expect(!fake.automaticallyDownloadsUpdates && !updates.automaticDownloads)
        updates.setAutomaticChecks(false)
        #expect(!fake.automaticallyChecksForUpdates && !updates.automaticChecks)
    }

    @Test("La versión instalada: «0.2.0 (412)»")
    func versionText() {
        #expect(AppUpdates.versionText(["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "412"]) == "0.2.0 (412)")
        #expect(AppUpdates.versionText(["CFBundleShortVersionString": "0.2.0"]) == "0.2.0")
        #expect(AppUpdates.versionText([:]) == nil)
        #expect(AppUpdates.versionText(nil) == nil)
    }

    @Test("Info.plist: Havebee, el mismo identificador y Sparkle apuntando a havebee.com")
    func infoPlist() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Info.plist").standardizedFileURL
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        #expect(plist["CFBundleName"] as? String == "Havebee")
        #expect(plist["CFBundleDisplayName"] as? String == "Havebee")
        #expect(plist["CFBundleExecutable"] as? String == "Havebee")
        // Ajustes y permiso de avisos dependen del identificador: no cambia con el nombre.
        #expect(plist["CFBundleIdentifier"] as? String == "com.lucianosanchez.hive")
        #expect(plist["SUFeedURL"] as? String == "https://havebee.com/downloads/appcast.xml")
        let key = try #require(plist["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32, "clave pública EdDSA de 32 bytes")
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
    }
}
