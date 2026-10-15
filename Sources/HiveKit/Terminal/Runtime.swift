import AppKit
import HiveCore
import Observation

/// Estado vivo de una sesión: su terminal y lo que está haciendo el agente.
@Observable @MainActor
public final class SessionRuntime {
    public let sessionId: UUID
    public let kind: SessionKind
    public internal(set) var status: SessionStatus = .dormant
    /// Terminó o pidió algo mientras no la estabas mirando.
    public internal(set) var unseen = false
    public internal(set) var title = ""
    var terminal: HiveTerminalView?
    /// Lo que pidió el agente al quedar esperando tu permiso (nil en cualquier otro estado).
    public var notice: String? { status == .attention ? attentionNotice : nil }
    var attentionNotice: String?
    /// La herramienta que pidió permiso, mientras siga en «Necesita permiso».
    @ObservationIgnored var pendingPermission: PermissionRequestKey?
    /// Se está armando su lanzamiento (búsquedas en disco fuera del hilo principal).
    public internal(set) var isLaunching = false

    @ObservationIgnored var events: TerminalEvents?
    /// Último momento en que la terminal recibió salida (para la regla del silencio).
    @ObservationIgnored var lastOutput = Date.distantPast
    /// Desde cuándo figura trabajando (para la regla del silencio y para mostrar cuánto lleva).
    @ObservationIgnored var workingSince: Date?
    /// Recibimos al menos un evento del agente (hooks / notify) en esta ejecución.
    @ObservationIgnored var hooksSeen = false

    init(sessionId: UUID, kind: SessionKind) {
        self.sessionId = sessionId
        self.kind = kind
    }

    public var isRunning: Bool {
        !status.isExited && terminal != nil
    }
}

/// Avisos de una terminal (cambio de título y fin del proceso) hacia quien la usa: una sesión o
/// un comando. La terminal la guarda como delegado débil: el dueño tiene que retenerla.
@MainActor
final class TerminalEvents: HiveTerminalDelegate {
    let onTitle: (String) -> Void
    let onExit: (HiveTerminalView, Int32?) -> Void

    init(onTitle: @escaping (String) -> Void = { _ in }, onExit: @escaping (HiveTerminalView, Int32?) -> Void) {
        self.onTitle = onTitle
        self.onExit = onExit
    }

    func terminalTitleChanged(_ terminal: HiveTerminalView, title: String) { onTitle(title) }

    func terminalProcessTerminated(_ terminal: HiveTerminalView, exitCode: Int32?) { onExit(terminal, exitCode) }
}

/// Un comando del proyecto corriendo (ej. `npm run dev`), con su propia terminal.
@Observable @MainActor
public final class CommandRun: Identifiable {
    public let id = UUID()
    public let projectId: UUID
    public let branchId: UUID
    public internal(set) var branchName: String
    public let commandId: UUID
    public internal(set) var name: String
    public internal(set) var command: String
    public internal(set) var directory: String
    /// Variables de entorno extra (para los scripts, ej. HIVE_BRANCH).
    let extraEnvironment: [String: String]
    /// Un script suelto (`runScript`), sin comando guardado en el proyecto.
    public let isScript: Bool
    var terminal: HiveTerminalView?
    public internal(set) var running = false
    public internal(set) var exitCode: Int32?
    public internal(set) var startedAt = Date()
    @ObservationIgnored var events: TerminalEvents?

    init(projectId: UUID, branchId: UUID, branchName: String, commandId: UUID, name: String, command: String, directory: String,
         extraEnvironment: [String: String] = [:], isScript: Bool = false) {
        self.extraEnvironment = extraEnvironment
        self.isScript = isScript
        self.projectId = projectId
        self.branchId = branchId
        self.branchName = branchName
        self.commandId = commandId
        self.name = name
        self.command = command
        self.directory = directory
    }
}
