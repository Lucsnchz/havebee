import AppKit
import HiveCore
import SwiftUI
import UserNotifications

/// Ajustes del usuario (en UserDefaults).
public struct AppSettings: Equatable, Sendable {
    /// Claude y Codex en la terminal normal: la charla queda en el scroll, también después de /clear.
    public var claudeInline: Bool
    /// Decirle a Claude y Codex dónde está el historial completo de la sesión.
    public var historyHint: Bool

    public init(claudeInline: Bool = true, historyHint: Bool = true) {
        self.claudeInline = claudeInline
        self.historyHint = historyHint
    }

    static let claudeInlineKey = "claudeInlineTerminal"
    static let historyHintKey = "historyHintForAgents"
    /// Sonido en los avisos del sistema (Bool, true por defecto).
    static let notificationSoundKey = "notificationSound"
    /// Uso de Claude en su barra de estado (Bool, true por defecto).
    static let showClaudeUsageKey = "showClaudeUsage"

    public static func read(_ defaults: UserDefaults = .standard) -> AppSettings {
        AppSettings(claudeInline: defaults.object(forKey: claudeInlineKey) as? Bool ?? true,
                    historyHint: defaults.object(forKey: historyHintKey) as? Bool ?? true)
    }
}

public struct SettingsView: View {
    private let dataFolder: URL

    public init(dataFolder: URL) {
        self.dataFolder = dataFolder
    }

    public var body: some View {
        TabView {
            SettingsGeneralPane(dataFolder: dataFolder)
                .tabItem { Label("General", systemImage: "gearshape") }
            SettingsTerminalPane()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            SettingsNotificationsPane()
                .tabItem { Label("Avisos", systemImage: "bell.badge") }
        }
        .frame(width: 540)
    }
}

/// Historial, agentes y datos.
struct SettingsGeneralPane: View {
    @AppStorage(AppSettings.claudeInlineKey) private var claudeInline = true
    @AppStorage(AppSettings.historyHintKey) private var historyHint = true
    @AppStorage(AppSettings.showClaudeUsageKey) private var showClaudeUsage = true
    let dataFolder: URL

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $claudeInline) {
                    Text("Claude y Codex en la terminal normal")
                    Text("La charla queda en el scroll de la terminal, también después de /clear, para leerla y copiarla. Si lo desactivás, usan su pantalla completa con su propio scroll.")
                }
                Toggle(isOn: $historyHint) {
                    Text("Avisarle a la IA que existe el historial")
                    Text("Claude y Codex saben dónde está el historial completo de la sesión (incluido lo anterior a cada /clear) y lo leen solo si hace falta.")
                }
            } header: {
                Text("Historial")
            } footer: {
                SettingsFooter("Los cambios se aplican al abrir o reiniciar cada sesión.")
            }
            Section("Agentes") {
                Toggle(isOn: $showClaudeUsage) {
                    Text("Mostrar uso de Claude en su barra")
                    Text("La barra de estado de Claude muestra cuánto usaste de tu límite. Se aplica al abrir o reiniciar la sesión.")
                }
            }
            Section {
                Button("Mostrar los datos de Hive en Finder") { NSWorkspace.shared.open(dataFolder) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Letra, cursor, tema y tecla Option de la terminal, y el editor para abrir archivos.
struct SettingsTerminalPane: View {
    @AppStorage(TerminalPreferences.fontNameKey) private var fontName = TerminalPreferences.systemFontName
    @AppStorage(TerminalPreferences.fontSizeKey) private var fontSize = TerminalPreferences.defaultFontSize
    @AppStorage(TerminalPreferences.cursorKey) private var cursor = TerminalPreferences.Cursor.blinkBlock.rawValue
    @AppStorage(TerminalPreferences.themeKey) private var theme = TerminalPreferences.Theme.system.rawValue
    @AppStorage(TerminalPreferences.optionKeyKey) private var optionKey = TerminalPreferences.OptionKey.characters.rawValue
    @AppStorage(ExternalApps.preferredEditorKey) private var preferredEditor = ""
    @State private var families: [String] = []
    @State private var editors: [ExternalApp] = []

    var body: some View {
        Form {
            Section {
                Picker("Fuente", selection: $fontName) {
                    ForEach(families.isEmpty ? [fontName] : families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("Tamaño") {
                    HStack(spacing: 8) {
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("Tamaño", value: $fontSize, in: TerminalPreferences.fontSizeRange, step: 1)
                            .labelsHidden()
                    }
                }
                Picker("Cursor", selection: cursorShape) {
                    ForEach(TerminalPreferences.CursorShape.allCases) { shape in
                        Text(shape.label).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Que parpadee", isOn: cursorBlinks)
                Picker("Tema", selection: $theme) {
                    ForEach(TerminalPreferences.Theme.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                Picker(selection: $optionKey) {
                    ForEach(TerminalPreferences.OptionKey.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                } label: {
                    Text("Tecla ⌥ Option")
                    Text("Desactivá Meta para escribir tildes, @ y corchetes. ⌥← y ⌥→ siguen saltando de a palabras.")
                }
            } header: {
                Text("Terminal")
            } footer: {
                SettingsFooter("Se aplica al instante en todas las terminales abiertas.")
            }
            Section("Editor") {
                Picker(selection: $preferredEditor) {
                    Text("El primero instalado").tag("")
                    ForEach(editors) { app in
                        Label { Text(app.name) } icon: { Image(nsImage: ExternalApps.icon(app)) }.tag(app.id)
                    }
                } label: {
                    Text("Abrir archivos con")
                    Text("Para ⌘clic en la terminal y «Abrir en el editor». Los proyectos de Android se abren en Android Studio y los de Xcode en Xcode.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            editors = ExternalApps.editors
            families = await Task.detached(priority: .userInitiated) { TerminalPreferences.monospacedFamilies() }.value
            if !families.contains(fontName) { families.append(fontName) }
        }
    }

    private var currentCursor: TerminalPreferences.Cursor {
        TerminalPreferences.Cursor(rawValue: cursor) ?? .blinkBlock
    }

    private var cursorShape: Binding<TerminalPreferences.CursorShape> {
        Binding(get: { currentCursor.shape },
                set: { cursor = TerminalPreferences.Cursor(shape: $0, blinking: currentCursor.blinks).rawValue })
    }

    private var cursorBlinks: Binding<Bool> {
        Binding(get: { currentCursor.blinks },
                set: { cursor = TerminalPreferences.Cursor(shape: currentCursor.shape, blinking: $0).rawValue })
    }
}

/// Estado de los avisos del sistema y sonido.
struct SettingsNotificationsPane: View {
    @AppStorage(AppSettings.notificationSoundKey) private var notificationSound = true
    @State private var status: UNAuthorizationStatus?

    /// Los avisos solo existen dentro de Hive.app (con bundle). En los tests y con `swift run`,
    /// UNUserNotificationCenter no se puede usar.
    static var canAskSystem: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Avisos de macOS") {
                    HStack(spacing: 6) {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusColor)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                if status == .denied {
                    Button("Abrir Ajustes del Sistema") { openSystemSettings() }
                }
                Toggle(isOn: $notificationSound) {
                    Text("Sonido en los avisos")
                    Text("Suena cuando una sesión termina su turno o necesita permiso.")
                }
            } header: {
                Text("Avisos")
            } footer: {
                SettingsFooter("Hive avisa cuando una sesión que no estás mirando te espera.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        guard Self.canAskSystem else { return }
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private var statusText: String {
        guard Self.canAskSystem else { return "Solo desde Hive.app" }
        switch status {
        case .authorized, .provisional, .ephemeral: return "Activados"
        case .denied: return "Desactivados"
        case .notDetermined: return "Todavía no los permitiste"
        case nil: return "Consultando…"
        @unknown default: return "Desconocido"
        }
    }

    private var statusSymbol: String {
        switch status {
        case .authorized, .provisional, .ephemeral: "checkmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        default: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case .authorized, .provisional, .ephemeral: .green
        case .denied: .red
        default: .secondary
        }
    }

    private func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Nota al pie de una sección de Ajustes.
private struct SettingsFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
