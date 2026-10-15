import AppKit
import HiveCore
import SwiftUI

/// La app (la arranca el ejecutable `Hive`).
public struct HiveApplication: App {
    /// Identificador de la ventana principal (también es el de su NSWindow).
    static let mainWindowId = "main"

    @NSApplicationDelegateAdaptor(HiveAppDelegate.self) private var appDelegate
    @State private var store = AppStore.shared
    @AppStorage("layout") private var layout: HiveLayout = .tree

    public init() {}

    public var body: some Scene {
        Window("Hive", id: Self.mainWindowId) {
            ContentView()
                .environment(store)
                .frame(minWidth: 880, minHeight: 540)
                // Con la vista compacta, barra de herramientas baja y sin título (las pestañas ya lo dicen).
                .background(WindowChrome(compact: layout == .compact))
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            HiveCommands(store: store)
        }

        Settings {
            SettingsView(dataFolder: store.environment.paths.root, agents: store.environment.agents)
        }
    }
}

final class HiveAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Hive tiene una sola ventana: sin pestañas de ventana (y sin «Nueva pestaña» en ⌘T).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necesario cuando se corre el binario suelto (swift run) en lugar del .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            let store = AppStore.shared
            store.start()
            if let notifier = store.environment.notifier as? SystemNotifier {
                notifier.onReply = { [weak store] id, text in
                    guard let store else { return }
                    ReplySender.send(text, sessionId: id, store: store)
                }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let handled = MainActor.assumeIsolated { HiveCommands.handleKeyDown(event) }
                return handled ? nil : event
            }
        }
    }

    /// Cerrar la ventana no corta las sesiones: siguen corriendo y avisando.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppStore.shared.appBecameActive() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            Self.terminateReply(store: AppStore.shared) { message in
                let alert = NSAlert()
                alert.messageText = message
                alert.informativeText = "Si salís se cortan. Las conversaciones se pueden reanudar al volver a abrir Hive."
                alert.addButton(withTitle: "Salir")
                alert.addButton(withTitle: "Cancelar")
                return alert.runModal() == .alertFirstButtonReturn
            }
        }
    }

    /// Si hay sesiones trabajando o comandos corriendo, pregunta con `confirm` antes de salir.
    /// Si cancelás, no se corta nada.
    @MainActor
    static func terminateReply(store: AppStore, confirm: (String) -> Bool) -> NSApplication.TerminateReply {
        if let message = QuitWarning.message(working: store.workingCount, commands: store.runningCommandsCount),
           !confirm(message) {
            return .terminateCancel
        }
        store.shutdown()
        return .terminateNow
    }
}

/// Ajusta la ventana según la vista: en la compacta, barra de herramientas baja y sin título.
/// La escena no puede cambiar `.windowToolbarStyle` según un ajuste, así que se hace en AppKit.
private struct WindowChrome: NSViewRepresentable {
    let compact: Bool

    func makeNSView(context: Context) -> WindowChromeView { WindowChromeView() }

    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.compact = compact
    }
}

private final class WindowChromeView: NSView {
    var compact = false {
        didSet { if compact != oldValue { apply() } }
    }
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI vuelve a mostrar el título cada vez que cambia: lo ocultamos de nuevo.
        observation = window?.observe(\.titleVisibility) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.hideTitleIfCompact(window) }
        }
        apply()
    }

    private func apply() {
        guard let window else { return }
        window.toolbarStyle = compact ? .unifiedCompact : .unified
        window.titleVisibility = compact ? .hidden : .visible
    }

    private func hideTitleIfCompact(_ window: NSWindow) {
        if compact && window.titleVisibility != .hidden { window.titleVisibility = .hidden }
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
