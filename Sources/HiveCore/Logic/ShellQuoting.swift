import Foundation

/// Rutas listas para pegar en una terminal (al soltar archivos o pegarlos).
public enum ShellQuoting {
    /// Caracteres que el shell no interpreta en ninguna posición de una palabra.
    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./+,@%:")

    /// La ruta tal cual si no tiene nada raro; si no, entre comillas simples (con '\'' para
    /// cada comilla de adentro). Espacios, ñ, tildes, $, *, ~ al principio: todo va entre comillas.
    public static func quote(_ path: String) -> String {
        if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Varias rutas escapadas, separadas por espacios y con un espacio al final (para seguir
    /// escribiendo). Vacío si no hay rutas.
    public static func pasteText(for paths: [String]) -> String {
        paths.isEmpty ? "" : paths.map(quote).joined(separator: " ") + " "
    }
}
