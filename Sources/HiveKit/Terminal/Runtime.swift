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

    @ObservationIgnored var bridge: TerminalBridge?
    @ObservationIgnored let activity = ActivityClock()
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

/// Último momento en que la terminal recibió salida.
final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date.distantPast

    func touch(_ date: Date = Date()) {
        lock.lock()
        value = date
        lock.unlock()
    }

    var last: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class TerminalBridge: NSObject, HiveTerminalDelegate {
    let sessionId: UUID
    weak var store: AppStore?

    init(sessionId: UUID, store: AppStore) {
        self.sessionId = sessionId
        self.store = store
    }

    func terminalTitleChanged(_ terminal: HiveTerminalView, title: String) {
        store?.runtimes[sessionId]?.title = title
    }

    func terminalProcessTerminated(_ terminal: HiveTerminalView, exitCode: Int32?) {
        store?.processExited(sessionId, terminal: terminal, code: exitCode)
    }
}

/// Un comando del proyecto corriendo (ej. `npm run dev`), con su propia terminal.
@Observable @MainActor
public final class CommandRun: Identifiable {
    public let id = UUID()
    public let projectId: UUID
    public let branchId: UUID
    public let branchName: String
    public let commandId: UUID
    public let name: String
    public let command: String
    public let directory: String
    var terminal: HiveTerminalView?
    public internal(set) var running = false
    public internal(set) var exitCode: Int32?
    public internal(set) var startedAt = Date()
    @ObservationIgnored var bridge: CommandBridge?

    init(projectId: UUID, branchId: UUID, branchName: String, commandId: UUID, name: String, command: String, directory: String) {
        self.projectId = projectId
        self.branchId = branchId
        self.branchName = branchName
        self.commandId = commandId
        self.name = name
        self.command = command
        self.directory = directory
    }
}

@MainActor
final class CommandBridge: NSObject, HiveTerminalDelegate {
    let runId: UUID
    weak var store: AppStore?

    init(runId: UUID, store: AppStore) {
        self.runId = runId
        self.store = store
    }

    func terminalTitleChanged(_ terminal: HiveTerminalView, title: String) {}

    func terminalProcessTerminated(_ terminal: HiveTerminalView, exitCode: Int32?) {
        store?.commandExited(runId, terminal: terminal, code: exitCode)
    }
}
