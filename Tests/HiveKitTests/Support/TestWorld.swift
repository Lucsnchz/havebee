import AppKit
import Foundation
import HiveCore
@testable import HiveKit

/// Avisos falsos: guarda lo que se habría mostrado.
@MainActor
final class FakeNotifier: SessionNotifying {
    struct Post: Equatable {
        let sessionId: UUID
        let title: String
        let subtitle: String
        let body: String
        /// El tipo de aviso, si quien avisó lo pasó (define los botones del aviso).
        var kind: NotificationKind?
    }

    var onOpen: ((UUID) -> Void)?
    private(set) var posts: [Post] = []
    private(set) var cleared: [UUID] = []
    private(set) var setupCalls = 0

    func setup() { setupCalls += 1 }
    func post(sessionId: UUID, title: String, subtitle: String, body: String) {
        posts.append(Post(sessionId: sessionId, title: title, subtitle: subtitle, body: body))
    }
    func post(sessionId: UUID, title: String, subtitle: String, body: String, kind: NotificationKind) {
        posts.append(Post(sessionId: sessionId, title: title, subtitle: subtitle, body: body, kind: kind))
    }
    func clear(_ sessionId: UUID) { cleared.append(sessionId) }
}

/// Procesos falsos: registra qué se lanzaría, sin lanzarlo.
@MainActor
final class FakeProcesses: ProcessStarting {
    struct Launch {
        let executable: String
        let args: [String]
        let environment: [String: String]
        let directory: String
    }

    var installed: Set<String> = ["claude", "codex", "gemini"]
    private(set) var launches: [Launch] = []

    func resolve(_ binary: String, path: String) -> String? {
        installed.contains(binary) ? "/fake/bin/\(binary)" : nil
    }

    func start(_ terminal: HiveTerminalView, executable: String, args: [String], environment: [String], directory: String) {
        var env: [String: String] = [:]
        for pair in environment {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            env[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        launches.append(Launch(executable: executable, args: args, environment: env, directory: directory))
    }
}

/// Todo lo que el store ve del mundo, controlable desde los tests.
@MainActor
final class TestWorld {
    let dir = TempDir("hive-world")
    let paths: HivePaths
    let home: URL
    let agents: AgentStorage
    let notifier = FakeNotifier()
    let processes = FakeProcesses()
    var settings = AppSettings()
    var appActive = false
    var now = Date.reference
    var badge: String?
    /// Logos por carpeta (el store los puede pedir fuera del hilo principal).
    var logos: [String: [String]] {
        get { logoTable.value }
        set { logoTable.value = newValue }
    }
    private let logoTable = LockedLogos()
    /// Lanzar sesiones armando el contexto en segundo plano, como la app. Por defecto no: así
    /// lanzar es inmediato y los tests no tienen que esperar.
    var launchesInBackground = false
    /// git real por defecto; los tests de carreras ponen uno con demoras (`DelayedGit`).
    var git: GitClient = GitCLI()

    init() {
        paths = HivePaths(root: dir.url.appendingPathComponent("Hive"))
        home = dir.subdir("home")
        agents = AgentStorage(claudeConfigDir: dir.subdir("claude"), codexHome: dir.subdir("codex"), geminiHome: dir.subdir("gemini"))
    }

    /// Con `weak` y no `unowned`: el store puede seguir vivo un rato después del test (una revisión de
    /// git que todavía corre lo retiene) y, al terminarla, recalcular el orden de los proyectos con la hora.
    var environment: AppEnvironment {
        AppEnvironment(
            paths: paths, git: git, agents: agents, notifier: notifier, processes: processes,
            settings: { [weak self] in self?.settings ?? AppSettings() },
            inheritedEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "CLAUDECODE": "1"],
            home: home, loginShell: "/bin/zsh", cachedLoginPATH: "/fake/bin:/usr/bin:/bin",
            resolveLoginPATH: { nil }, storeLoginPATH: { _ in },
            logos: { [logoTable] path in logoTable.value[path] ?? [] },
            isAppActive: { [weak self] in self?.appActive ?? false },
            setDockBadge: { [weak self] in self?.badge = $0 },
            now: { [weak self] in self?.now ?? .reference },
            saveDelay: 0,
            stopGrace: 0.2,
            launchesInBackground: launchesInBackground)
    }

    func makeStore() -> AppStore { AppStore(environment: environment) }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Tabla de logos que se puede leer desde cualquier hilo.
private final class LockedLogos: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [String]] = [:]

    var value: [String: [String]] {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue } }
    }
}

/// Espera (cediendo el hilo principal) hasta que se cumpla una condición. El margen es amplio a
/// propósito: todos los tests @MainActor comparten el hilo principal (al arrancar la corrida, decenas
/// crean repos con git y dibujan vistas a la vez) y la máquina puede estar cargada. Devuelve apenas
/// se cumple, así que el margen solo se nota cuando algo de verdad falla.
@MainActor
func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}
