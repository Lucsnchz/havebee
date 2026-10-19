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
    /// Llega por la salida, entre marcas, así no se mezcla con lo que impriman los archivos de
    /// arranque del shell. Antes iba a un archivo temporal que quedaba tirado si Hive se cerraba
    /// (o dejaba de esperar) antes de que el shell terminara de arrancar.
    public static func resolvePATH(shell: String = path, timeout: TimeInterval = 8,
                                   runner: CommandRunning = ProcessCommandRunner()) -> String? {
        let script = "printf '\(pathMarker)%s\(pathMarker)' \"$PATH\""
        let r = runner.run(shell, ["-l", "-i", "-c", script], cwd: nil, environment: [:], timeout: timeout)
        guard r.ok else { return nil }
        let parts = r.stdout.components(separatedBy: pathMarker)
        guard parts.count >= 3, !parts[parts.count - 2].isEmpty else { return nil }
        return parts[parts.count - 2]
    }

    private static let pathMarker = "__HIVE_PATH__"

    /// PATH razonable mientras no tenemos el real.
    public static func fallbackPATH(home: String = NSHomeDirectory(), inherited: String? = ProcessInfo.processInfo.environment["PATH"]) -> String {
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in (inherited ?? "").split(separator: ":").map(String.init) where !dirs.contains(dir) {
            dirs.append(dir)
        }
        return dirs.joined(separator: ":")
    }
}
