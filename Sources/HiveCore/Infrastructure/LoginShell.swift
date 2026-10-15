import Foundation

public enum LoginShell {
    /// El shell del usuario (de su cuenta, o $SHELL).
    public static var path: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let shell = String(cString: sh)
            if !shell.isEmpty { return shell }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// El PATH que ve una terminal nueva (shell de login interactivo). Una app abierta desde
    /// Finder arranca con un PATH mínimo, así que sin esto no encontraríamos `claude` ni `codex`.
    public static func resolvePATH(shell: String = path, timeout: TimeInterval = 8) -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hive-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '%s' \"$PATH\" > \(shellQuote(file.path))"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        guard let value = try? String(contentsOf: file, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// PATH razonable mientras no tenemos el real.
    public static func fallbackPATH(home: String = NSHomeDirectory(), inherited: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in (inherited ?? "").split(separator: ":").map(String.init) where !dirs.contains(dir) {
            dirs.append(dir)
        }
        return dirs.joined(separator: ":")
    }
}
