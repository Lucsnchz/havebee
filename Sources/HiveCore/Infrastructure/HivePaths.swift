import Foundation

/// Dónde guarda Hive sus datos. Es un valor (no un global) para que los tests usen una carpeta temporal.
public struct HivePaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `HIVE_HOME` permite usar otra carpeta (útil para probar sin tocar tu estado real).
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> HivePaths {
        if let home = environment["HIVE_HOME"], !home.isEmpty {
            return HivePaths(root: URL(fileURLWithPath: home, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HivePaths(root: support.appendingPathComponent("Hive", isDirectory: true))
    }

    public var stateFile: URL { root.appendingPathComponent("state.json") }
    public var eventsDir: URL { root.appendingPathComponent("events", isDirectory: true) }
    public var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var eventBin: URL { binDir.appendingPathComponent("hive-event") }
    public var claudeSettings: URL { root.appendingPathComponent("claude-settings.json") }
    /// Los mismos ajustes más el statusLine de Hive, que guarda el uso de contexto y los límites de Claude.
    public var claudeSettingsWithUsage: URL { root.appendingPathComponent("claude-settings-usage.json") }
    /// Lo último que Claude le pasó al statusLine de cada sesión (usage/<sesión>.json).
    public var usageDir: URL { root.appendingPathComponent("usage", isDirectory: true) }
    public var historyDir: URL { root.appendingPathComponent("history", isDirectory: true) }
    public var iconsDir: URL { root.appendingPathComponent("icons", isDirectory: true) }
    public var geminiDir: URL { root.appendingPathComponent("gemini", isDirectory: true) }
}

/// Compara rutas resolviendo `..`, barras finales y enlaces simbólicos (ej. /tmp → /private/tmp).
public func samePath(_ a: String, _ b: String) -> Bool {
    func normalize(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path
    }
    return normalize(a) == normalize(b)
}
