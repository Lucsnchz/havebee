import Foundation
import Observation

/// Lo que la app sabe hacer para actualizarse. La implementa el ejecutable con Sparkle; HiveKit (y
/// sus tests) no carga Sparkle, solo habla con esto.
@MainActor
public protocol AppUpdating: AnyObject {
    /// Si ahora se puede buscar (no hay otra búsqueda o instalación en curso).
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    /// Busca ya y muestra el resultado (también «Ya tenés la última versión»).
    func checkForUpdates()
    /// Avisa cada vez que cambia `canCheckForUpdates`.
    func observeCanCheck(_ change: @escaping @MainActor (Bool) -> Void)
}

/// Las actualizaciones de la app, para el menú y los ajustes. Sin un `AppUpdating` conectado (al
/// correr con `swift run` o en los tests) no hay nada que mostrar.
@MainActor
@Observable
public final class AppUpdates {
    public static let shared = AppUpdates()

    @ObservationIgnored private var updater: AppUpdating?
    public private(set) var canCheck = false
    /// Copias para que la vista se redibuje al cambiarlas; el valor de verdad lo guarda el updater.
    public private(set) var automaticChecks = false
    public private(set) var automaticDownloads = false

    public init() {}

    public var isAvailable: Bool { updater != nil }

    public func connect(_ updater: AppUpdating) {
        self.updater = updater
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
        canCheck = updater.canCheckForUpdates
        updater.observeCanCheck { [weak self] in self?.canCheck = $0 }
    }

    public func checkForUpdates() {
        updater?.checkForUpdates()
    }

    public func setAutomaticChecks(_ on: Bool) {
        updater?.automaticallyChecksForUpdates = on
        automaticChecks = updater?.automaticallyChecksForUpdates ?? false
    }

    public func setAutomaticDownloads(_ on: Bool) {
        updater?.automaticallyDownloadsUpdates = on
        automaticDownloads = updater?.automaticallyDownloadsUpdates ?? false
    }

    /// La versión instalada, para los ajustes: «0.2.0 (412)».
    public static func versionText(_ info: [String: Any]?) -> String? {
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}
