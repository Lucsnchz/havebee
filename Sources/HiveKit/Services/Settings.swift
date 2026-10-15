import AppKit
import HiveCore
import SwiftUI

/// Ajustes del usuario (en UserDefaults).
public struct AppSettings: Equatable, Sendable {
    /// Claude en la terminal normal: la charla queda en el scroll, también después de /clear.
    public var claudeInline: Bool
    /// Decirle a Claude y Codex dónde está el historial completo de la sesión.
    public var historyHint: Bool

    public init(claudeInline: Bool = true, historyHint: Bool = true) {
        self.claudeInline = claudeInline
        self.historyHint = historyHint
    }

    static let claudeInlineKey = "claudeInlineTerminal"
    static let historyHintKey = "historyHintForAgents"

    public static func read(_ defaults: UserDefaults = .standard) -> AppSettings {
        AppSettings(claudeInline: defaults.object(forKey: claudeInlineKey) as? Bool ?? true,
                    historyHint: defaults.object(forKey: historyHintKey) as? Bool ?? true)
    }
}

public struct SettingsView: View {
    @AppStorage(AppSettings.claudeInlineKey) private var claudeInline = true
    @AppStorage(AppSettings.historyHintKey) private var historyHint = true
    private let dataFolder: URL

    public init(dataFolder: URL) {
        self.dataFolder = dataFolder
    }

    public var body: some View {
        Form {
            Section("Historial") {
                Toggle("Claude en la terminal normal", isOn: $claudeInline)
                Text("La charla queda en el scroll de la terminal, también después de /clear, para leerla y copiarla. Si lo desactivás, Claude usa su pantalla completa con su propio scroll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Avisarle a la IA que existe el historial", isOn: $historyHint)
                Text("Claude y Codex saben dónde está el historial completo de la sesión (incluido lo anterior a cada /clear) y lo leen solo si hace falta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Los cambios se aplican al abrir o reiniciar cada sesión.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Section {
                Button("Mostrar los datos de Hive en Finder") { NSWorkspace.shared.open(dataFolder) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
