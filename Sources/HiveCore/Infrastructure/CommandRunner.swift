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
}

extension CommandRunning {
    public func run(_ executable: String, _ args: [String], cwd: String? = nil) -> CommandResult {
        run(executable, args, cwd: cwd, environment: [:])
    }
}

/// Implementación real con `Process`. Bloquea el hilo: llamarla fuera del principal.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ args: [String], cwd: String?, environment extra: [String: String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extra { env[key] = value }
        process.environment = env
        // stdout por un pipe que leemos en este hilo; stderr a un archivo temporal, que nunca se
        // llena. Así no hace falta otro hilo: leer los dos pipes con GCD trababa el proceso cuando
        // había muchas llamadas en paralelo y se agotaban los hilos (el pipe de stderr se llenaba).
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("hive-stderr-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: errFile.path, contents: nil),
              let errHandle = try? FileHandle(forWritingTo: errFile) else {
            return CommandResult(status: -1, stderr: "No se pudo crear un archivo temporal.")
        }
        defer { try? FileManager.default.removeItem(at: errFile) }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        // Esperamos con un semáforo y no con `waitUntilExit()`: ese hace girar el run loop del hilo
        // actual y, en el principal, ejecuta otro trabajo pendiente en medio de esta llamada.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? errHandle.close()
            return CommandResult(status: -1, stderr: error.localizedDescription)
        }
        try? errHandle.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        let errData = (try? Data(contentsOf: errFile)) ?? Data()
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
