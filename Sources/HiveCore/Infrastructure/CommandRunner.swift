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

    public var timedOut: Bool { status == Self.timedOutStatus }
}

/// Implementación real con `Process`. Bloquea el hilo: llamarla fuera del principal.
public struct ProcessCommandRunner: CommandRunning {
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
        // stdout y stderr van a dos archivos temporales, que nunca se llenan: el proceso escribe los
        // dos en paralelo sin depender de que alguien lea, y no hace falta ningún hilo lector. Leer
        // pipes con GCD trababa el proceso cuando había muchas llamadas en paralelo y se agotaban los
        // hilos; y con un pipe, un nieto que hereda la salida (ssh, un hook) impediría cortar a tiempo.
        let tmp = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let outFile = tmp.appendingPathComponent("hive-stdout-\(id)")
        let errFile = tmp.appendingPathComponent("hive-stderr-\(id)")
        guard FileManager.default.createFile(atPath: outFile.path, contents: nil),
              FileManager.default.createFile(atPath: errFile.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: outFile),
              let errHandle = try? FileHandle(forWritingTo: errFile) else {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
            return CommandResult(status: -1, stderr: "No se pudo crear un archivo temporal.")
        }
        defer {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        // Esperamos con un semáforo y no con `waitUntilExit()`: ese hace girar el run loop del hilo
        // actual y, en el principal, ejecuta otro trabajo pendiente en medio de esta llamada.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            return CommandResult(status: -1, stderr: error.localizedDescription)
        }
        try? outHandle.close()
        try? errHandle.close()
        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + max(timeout, 0)) == .timedOut {
                timedOut = true
                // terminate() le manda SIGTERM al hijo y a lo que lanzó: Process lo deja en su propio grupo.
                process.terminate()
                // Si no se va con SIGTERM, lo matamos con todo su grupo (ssh, un hook de git), que si
                // no quedaría vivo.
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    let pid = process.processIdentifier
                    kill(-pid, SIGKILL)
                    kill(pid, SIGKILL)
                    _ = exited.wait(timeout: .now() + 2)
                }
            }
        } else {
            exited.wait()
        }
        let outData = (try? Data(contentsOf: outFile)) ?? Data()
        let errData = (try? Data(contentsOf: errFile)) ?? Data()
        if timedOut {
            let seconds = String(format: "%g", timeout ?? 0)
            return CommandResult(status: CommandResult.timedOutStatus,
                                 stdout: String(decoding: outData, as: UTF8.self),
                                 stderr: "Tardó demasiado: se canceló después de \(seconds) s.")
        }
        return CommandResult(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
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
