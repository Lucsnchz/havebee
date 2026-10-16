import AppKit
import Foundation
import HiveCore

/// Arranca procesos en terminales. Es un protocolo para que los tests vean qué se lanzaría sin lanzarlo.
@MainActor
public protocol ProcessStarting: AnyObject {
    /// Ruta del binario en el PATH, o nil si no está instalado.
    func resolve(_ binary: String, path: String) -> String?
    func start(_ terminal: HiveTerminalView, executable: String, args: [String], environment: [String], directory: String)
}

@MainActor
public final class TerminalProcessStarter: ProcessStarting {
    public init() {}

    public func resolve(_ binary: String, path: String) -> String? {
        which(binary, path: path)
    }

    public func start(_ terminal: HiveTerminalView, executable: String, args: [String], environment: [String], directory: String) {
        terminal.startProcess(executable: executable, args: args, environment: environment, currentDirectory: directory)
    }
}

/// Todo lo que el store necesita del mundo exterior. En la app se usa `.live()`; en los tests,
/// carpetas temporales, git real sobre repos de prueba y versiones falsas de lo demás.
@MainActor
public struct AppEnvironment {
    public var paths: HivePaths
    public var git: GitClient
    public var agents: AgentStorage
    public var notifier: SessionNotifying
    public var processes: ProcessStarting
    public var settings: () -> AppSettings
    /// Variables de entorno heredadas (se limpian antes de pasarlas a las sesiones).
    public var inheritedEnvironment: [String: String]
    public var home: URL
    public var loginShell: String
    /// PATH de la última vez (para no esperar a resolverlo al arrancar).
    public var cachedLoginPATH: String?
    public var resolveLoginPATH: @Sendable () -> String?
    public var storeLoginPATH: (String) -> Void
    /// Logos encontrados en un repo. Se puede llamar fuera del hilo principal (lee archivos).
    public var logos: @Sendable (String) -> [String]
    public var isAppActive: () -> Bool
    public var setDockBadge: (String?) -> Void
    public var now: () -> Date
    /// Espera antes de guardar el estado (agrupa cambios seguidos). En los tests suele ser 0.
    public var saveDelay: TimeInterval
    /// Plazo entre el Ctrl+C de «Detener» y cortar el comando si no terminó.
    public var stopGrace: TimeInterval
    /// Armar el lanzamiento de las sesiones fuera del hilo principal (en la app, sí; en los tests,
    /// por defecto no, para que lanzar sea inmediato).
    public var launchesInBackground: Bool
    /// Dónde empieza y termina el día (para ordenar los proyectos por «usados hoy»).
    public var calendar: Calendar

    public init(paths: HivePaths, git: GitClient, agents: AgentStorage, notifier: SessionNotifying, processes: ProcessStarting,
                settings: @escaping () -> AppSettings, inheritedEnvironment: [String: String], home: URL, loginShell: String,
                cachedLoginPATH: String?, resolveLoginPATH: @escaping @Sendable () -> String?, storeLoginPATH: @escaping (String) -> Void,
                logos: @escaping @Sendable (String) -> [String], isAppActive: @escaping () -> Bool, setDockBadge: @escaping (String?) -> Void,
                now: @escaping () -> Date, saveDelay: TimeInterval, stopGrace: TimeInterval = 3,
                launchesInBackground: Bool = true, calendar: Calendar = .autoupdatingCurrent) {
        self.paths = paths
        self.git = git
        self.agents = agents
        self.notifier = notifier
        self.processes = processes
        self.settings = settings
        self.inheritedEnvironment = inheritedEnvironment
        self.home = home
        self.loginShell = loginShell
        self.cachedLoginPATH = cachedLoginPATH
        self.resolveLoginPATH = resolveLoginPATH
        self.storeLoginPATH = storeLoginPATH
        self.logos = logos
        self.isAppActive = isAppActive
        self.setDockBadge = setDockBadge
        self.now = now
        self.saveDelay = saveDelay
        self.stopGrace = stopGrace
        self.launchesInBackground = launchesInBackground
        self.calendar = calendar
    }

    public static func live() -> AppEnvironment {
        let env = ProcessInfo.processInfo.environment
        let finder = LogoFinder(isUsable: { path in
            // NSImage es seguro de usar fuera del hilo principal para leer archivos.
            isUsableLogo(path)
        })
        return AppEnvironment(
            paths: .live(environment: env),
            git: GitCLI(),
            agents: .live(environment: env),
            notifier: SystemNotifier(),
            processes: TerminalProcessStarter(),
            settings: { AppSettings.read() },
            inheritedEnvironment: env,
            home: FileManager.default.homeDirectoryForCurrentUser,
            loginShell: LoginShell.path,
            cachedLoginPATH: UserDefaults.standard.string(forKey: "loginPATH"),
            resolveLoginPATH: { LoginShell.resolvePATH() },
            storeLoginPATH: { UserDefaults.standard.set($0, forKey: "loginPATH") },
            logos: { finder.find(in: $0) },
            isAppActive: { NSApp.isActive && NSApp.keyWindow?.isVisible == true },
            setDockBadge: { NSApp?.dockTile.badgeLabel = $0 },
            now: Date.init,
            saveDelay: 0.4,
            stopGrace: 3,
            launchesInBackground: true)
    }
}
