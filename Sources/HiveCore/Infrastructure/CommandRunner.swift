import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var ok: Bool { status == 0 }
    public var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var errorMessage: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? output : err
    }
}

/// Corre un programa y espera a que termine. Es un protocolo para poder reemplazarlo en los tests.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ args: [String], cwd: String?, environment: [String: String]) -> CommandResult
    /// Igual, pero si el programa tarda más de `timeout` segundos lo corta y devuelve el status -2.
    func run(_ executable: String, _ args: [String], cwd: String?, environment: [String: String], timeout: TimeInterval) -> CommandResult
}

extension CommandRunning {
    public func run(_ executable: String, _ args: [String], cwd: String? = nil) -> CommandResult {
        run(executable, args, cwd: cwd, environment: [:])
    }

    /// Por defecto no hay límite: los runners que no saben cortar un proceso esperan a que termine.
    public func run(_ executable: String, _ args: [String], cwd: String?, environment: [String: String], timeout: TimeInterval) -> CommandResult {
        run(executable, args, cwd: cwd, environment: environment)
    }
}

extension CommandResult {
    /// Status de un proceso que se cortó por tardar demasiado.
    public static let timedOutStatus: Int32 = -2
    /// Status de un proceso que se cortó porque cancelaste la tarea que lo esperaba (`CancellableWork`).
    public static let cancelledStatus: Int32 = -3

    public var timedOut: Bool { status == Self.timedOutStatus }
    public var cancelled: Bool { status == Self.cancelledStatus }
}

/// Corre trabajo que lanza procesos (git, por ejemplo) fuera del hilo principal. Si se cancela la
/// tarea que lo espera, se corta el proceso que esté corriendo en ese momento (con lo que lanzó: un
/// hook, ssh) y vuelve con `CommandResult.cancelledStatus`. Es a pedido: el resto de las llamadas
/// no se cortan aunque su tarea se cancele (una revisión de git a medias se tomaría por un error).
public enum CancellableWork {
    public static func run<T: Sendable>(priority: TaskPriority? = nil, _ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: priority) {
            ProcessCommandRunner.$cancelsWithTask.withValue(true) { work() }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

/// Implementación real con `Process`. Bloquea el hilo: llamarla fuera del principal.
public struct ProcessCommandRunner: CommandRunning {
    /// Adentro de `CancellableWork.run`: cancelar la tarea corta el proceso.
    @TaskLocal public static var cancelsWithTask = false

    public init() {}

    public func run(_ executable: String, _ args: [String], cwd: String?, environment extra: [String: String]) -> CommandResult {
        execute(executable, args, cwd: cwd, environment: extra, timeout: nil)
    }

    public func run(_ executable: String, _ args: [String], cwd: String?, environment extra: [String: String], timeout: TimeInterval) -> CommandResult {
        execute(executable, args, cwd: cwd, environment: extra, timeout: timeout)
    }

    private func execute(_ executable: String, _ args: [String], cwd: String?, environment extra: [String: String], timeout: TimeInterval?) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extra { env[key] = value }
        process.environment = env
        // stdout y stderr van a pipes que lee este mismo hilo mientras espera al proceso. No se usan
        // archivos temporales: la revisión de git crea y borra decenas por segundo, y macOS contó
        // 34 GB escritos en 14 horas. Tampoco hilos lectores de GCD, que con muchas llamadas en
        // paralelo se agotaban y trababan el proceso. Y si un nieto hereda la salida (ssh, un hook),
        // no se espera a que la suelte: alcanza con que termine el proceso.
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // Esperamos con un semáforo y no con `waitUntilExit()`: ese hace girar el run loop del hilo
        // actual y, en el principal, ejecuta otro trabajo pendiente en medio de esta llamada.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let cancellable = Self.cancelsWithTask
        if cancellable && Task.isCancelled {
            return CommandResult(status: CommandResult.cancelledStatus, stderr: "Se canceló.")
        }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stderr: error.localizedDescription)
        }
        // Process ya cerró nuestra copia de los extremos de escritura: cada pipe llega al final
        // cuando el hijo (y lo que lanzó) lo suelta.
        var reader = OutputReader(output: output.fileHandleForReading, errors: errors.fileHandleForReading)
        defer { reader.close() }
        let outcome = Self.wait(for: exited, timeout: timeout, cancellable: cancellable, reading: &reader)
        if outcome != .exited {
            // terminate() le manda SIGTERM al hijo y a lo que lanzó: Process lo deja en su propio grupo.
            process.terminate()
            // Si no se va con SIGTERM, lo matamos con todo su grupo (ssh, un hook de git), que si
            // no quedaría vivo.
            if !reader.read(until: .now() + 2, orExit: exited) {
                let pid = process.processIdentifier
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                _ = reader.read(until: .now() + 2, orExit: exited)
            }
        }
        // Lo que dejó antes de terminar ya está en los pipes.
        reader.readAvailable()
        let outData = reader.output
        let errData = reader.errors
        switch outcome {
        case .timedOut:
            let seconds = String(format: "%g", timeout ?? 0)
            return CommandResult(status: CommandResult.timedOutStatus,
                                 stdout: String(decoding: outData, as: UTF8.self),
                                 stderr: "Tardó demasiado: se canceló después de \(seconds) s.")
        case .cancelled:
            return CommandResult(status: CommandResult.cancelledStatus, stdout: String(decoding: outData, as: UTF8.self),
                                 stderr: "Se canceló.")
        case .exited:
            break
        }
        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }

    private enum Outcome { case exited, timedOut, cancelled }

    /// Espera a que termine, como mucho `timeout` segundos, leyendo su salida mientras tanto. Si es
    /// cancelable, cada décima de segundo se fija si cancelaron la tarea.
    private static func wait(for exited: DispatchSemaphore, timeout: TimeInterval?, cancellable: Bool,
                             reading reader: inout OutputReader) -> Outcome {
        let deadline = timeout.map { DispatchTime.now() + max($0, 0) }
        while true {
            var slice = DispatchTime.now() + 0.1
            if let deadline, deadline < slice { slice = deadline }
            if reader.read(until: slice, orExit: exited) { return .exited }
            if cancellable && Task.isCancelled { return .cancelled }
            if let deadline, DispatchTime.now() >= deadline { return .timedOut }
        }
    }
}

/// Lee stdout y stderr de un proceso desde el hilo que lo espera, sin bloquearse en ninguno de los
/// dos: si uno se llenara mientras se espera el otro, el proceso quedaría trabado escribiendo.
private struct OutputReader {
    private(set) var output = Data()
    private(set) var errors = Data()
    private let handles: [FileHandle]
    private var open = [true, true]
    private var buffer = [UInt8](repeating: 0, count: 65_536)

    init(output: FileHandle, errors: FileHandle) {
        handles = [output, errors]
        for handle in handles {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
    }

    /// Lee hasta `limit` y vuelve antes, con true, si el proceso terminó.
    mutating func read(until limit: DispatchTime, orExit exited: DispatchSemaphore) -> Bool {
        while open.contains(true) {
            if exited.wait(timeout: .now()) == .success { return true }
            let now = DispatchTime.now()
            guard now < limit else { return false }
            let remaining = (limit.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000
            var fds = (0..<2).map { pollfd(fd: open[$0] ? handles[$0].fileDescriptor : -1, events: Int16(POLLIN), revents: 0) }
            // Con un nieto que tiene la salida abierta no llega el final: cada décima se revisa si terminó.
            guard poll(&fds, 2, Int32(max(1, min(remaining, 100)))) > 0 else { continue }
            for i in 0..<2 where open[i] && fds[i].revents != 0 { drain(i) }
        }
        // Sin salida abierta solo queda esperar a que termine.
        return exited.wait(timeout: limit) == .success
    }

    /// Lee lo que haya sin esperar más.
    mutating func readAvailable() {
        for i in 0..<2 where open[i] { drain(i) }
    }

    func close() {
        for handle in handles { try? handle.close() }
    }

    private mutating func drain(_ index: Int) {
        let fd = handles[index].fileDescriptor
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                if index == 0 { output.append(contentsOf: buffer[0..<count]) } else { errors.append(contentsOf: buffer[0..<count]) }
            } else if count == 0 || errno != EINTR {
                // 0 es el final; EAGAIN, que por ahora no hay más.
                if count == 0 || errno != EAGAIN { open[index] = false }
                return
            }
        }
    }
}

/// Busca un ejecutable en un PATH.
public func which(_ name: String, path: String) -> String? {
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Comillas simples para pasar un texto a `sh -c`.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
