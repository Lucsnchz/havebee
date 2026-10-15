import AppKit
import HiveCore
import SwiftUI

/// La app (la arranca el ejecutable `Hive`).
public struct HiveApplication: App {
    @NSApplicationDelegateAdaptor(HiveAppDelegate.self) private var appDelegate
    @State private var store = AppStore.shared
    @AppStorage("layout") private var layout: HiveLayout = .tree

    public init() {}

    public var body: some Scene {
        Window("Hive", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 880, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Agregar proyecto…") { store.addProjectInteractive() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Ir") {
                Button("Buscar…") { store.showSwitcher = true }
                    .keyboardShortcut("k")
            }
            CommandGroup(before: .sidebar) {
                Picker("Vista", selection: $layout) {
                    Text("Árbol").tag(HiveLayout.tree)
                    Text("Compacta").tag(HiveLayout.compact)
                }
                .pickerStyle(.inline)
                Divider()
            }
        }

        Settings {
            SettingsView(dataFolder: store.environment.paths.root)
        }
    }
}

final class HiveAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necesario cuando se corre el binario suelto (swift run) en lugar del .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { AppStore.shared.start() }
    }

    /// Cerrar la ventana no corta las sesiones: siguen corriendo y avisando.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppStore.shared.appBecameActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let store = AppStore.shared
            if let message = QuitWarning.message(working: store.workingCount, commands: store.runningCommandsCount) {
                let alert = NSAlert()
                alert.messageText = message
                alert.informativeText = "Si salís se cortan. Las conversaciones se pueden reanudar al volver a abrir Hive."
                alert.addButton(withTitle: "Salir")
                alert.addButton(withTitle: "Cancelar")
                if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            }
            store.shutdown()
            return .terminateNow
        }
    }
}

/// Aviso al salir si hay cosas corriendo.
enum QuitWarning {
    static func message(working: Int, commands: Int) -> String? {
        var parts: [String] = []
        if working > 0 { parts.append(working == 1 ? "una sesión trabajando" : "\(working) sesiones trabajando") }
        if commands > 0 { parts.append(commands == 1 ? "un comando corriendo" : "\(commands) comandos corriendo") }
        return parts.isEmpty ? nil : "Hay " + parts.joined(separator: " y ")
    }
}

extension Color {
    static let honey = Color(red: 0.96, green: 0.72, blue: 0.24)
}

extension SessionKind {
    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.45, green: 0.66, blue: 0.96)
        case .gemini: Color(red: 0.45, green: 0.50, blue: 0.98)
        case .shell: .secondary
        }
    }
}
