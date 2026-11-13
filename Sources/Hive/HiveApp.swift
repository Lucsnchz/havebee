import AppKit
import HiveKit
import Sparkle

/// Punto de entrada: toda la app vive en HiveKit (y su lógica en HiveCore). Acá solo se conecta
/// Sparkle, para que HiveKit y sus tests no lo carguen.
@main
enum HiveMain {
    static func main() {
        MainActor.assumeIsolated {
            if let updater = SparkleUpdater.makeIfBundled() {
                AppUpdates.shared.connect(updater)
            }
        }
        HiveApplication.main()
    }
}

/// Las actualizaciones con Sparkle: lee el appcast de SUFeedURL (Info.plist) y verifica cada
/// descarga con la clave pública SUPublicEDKey.
@MainActor
final class SparkleUpdater: AppUpdating {
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    /// Solo dentro de Havebee.app con un appcast configurado: con `swift run` Sparkle no tiene
    /// bundle que reemplazar y mostraría un error al arrancar.
    static func makeIfBundled() -> SparkleUpdater? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return nil }
        return SparkleUpdater()
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func observeCanCheck(_ change: @escaping @MainActor (Bool) -> Void) {
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in change(value) }
        }
    }
}
