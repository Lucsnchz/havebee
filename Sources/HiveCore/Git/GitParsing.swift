import Foundation

/// Lectura de la salida de git. Funciones puras: se prueban con texto, sin repos.
public enum GitParsing {
    /// `git status --porcelain=v1 -b`.
    public static func status(_ text: String) -> GitStatus {
        var status = GitStatus()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                var header = String(line.dropFirst(3))
                if let bracket = header.range(of: " [") {
                    let info = header[bracket.upperBound...].dropLast()
                    for part in info.split(separator: ",") {
                        let item = part.trimmingCharacters(in: .whitespaces)
                        if item.hasPrefix("ahead ") { status.ahead = Int(item.dropFirst(6)) ?? 0 }
                        if item.hasPrefix("behind ") { status.behind = Int(item.dropFirst(7)) ?? 0 }
                    }
                    header = String(header[..<bracket.lowerBound])
                }
                if header.hasPrefix("No commits yet on ") {
                    status.branch = String(header.dropFirst("No commits yet on ".count))
                } else if header.hasPrefix("HEAD (no branch)") {
                    status.branch = nil
                } else if let dots = header.range(of: "...") {
                    status.branch = String(header[..<dots.lowerBound])
                    status.upstream = String(header[dots.upperBound...])
                } else {
                    status.branch = header
                }
            } else if line.count > 3 {
                let code = String(line.prefix(2))
                var path = String(line.dropFirst(3))
                if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
                if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
                status.changes.append(GitChange(code: code, path: path))
            }
        }
        return status
    }

    /// `git worktree list --porcelain`.
    public static func worktrees(_ text: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var current: GitWorktree?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let current { result.append(current) }
                current = GitWorktree(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("branch ") {
                var ref = String(line.dropFirst("branch ".count))
                if ref.hasPrefix("refs/heads/") { ref.removeFirst("refs/heads/".count) }
                current?.branch = ref
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// `git log --format=%h%x1f%s%x1f%an%x1f%ct`.
    public static func commits(_ text: String) -> [GitCommit] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let seconds = TimeInterval(parts[3]) else { return nil }
            return GitCommit(hash: parts[0], subject: parts[1], author: parts[2], date: Date(timeIntervalSince1970: seconds))
        }
    }

    public static let maxDiffLines = 4000

    /// Diff unificado de un archivo, con números de línea viejos y nuevos.
    public static func diff(_ text: String, maxLines: Int = maxDiffLines) -> FileDiff {
        var diff = FileDiff()
        var old = 0
        var new = 0
        var inHunk = false
        let rawLines = text.components(separatedBy: "\n")
        for (index, line) in rawLines.enumerated() {
            if diff.lines.count >= maxLines { diff.truncated = true; break }
            if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { diff.isBinary = true; continue }
            if line.hasPrefix("@@") {
                // @@ -12,7 +12,9 @@ contexto
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                inHunk = true
                diff.lines.append(DiffLine(id: diff.lines.count, kind: .hunk, oldNumber: nil, newNumber: nil, text: line))
                continue
            }
            if line.hasPrefix("diff --git") { inHunk = false; continue }
            guard inHunk else { continue } // encabezados (index, ---, +++)
            // La línea vacía que deja el salto final no es contexto.
            if line.isEmpty && index == rawLines.count - 1 { continue }
            if line.hasPrefix("+") {
                diff.lines.append(DiffLine(id: diff.lines.count, kind: .added, oldNumber: nil, newNumber: new, text: String(line.dropFirst())))
                new += 1
            } else if line.hasPrefix("-") {
                diff.lines.append(DiffLine(id: diff.lines.count, kind: .removed, oldNumber: old, newNumber: nil, text: String(line.dropFirst())))
                old += 1
            } else if line.hasPrefix("\\") {
                diff.lines.append(DiffLine(id: diff.lines.count, kind: .note, oldNumber: nil, newNumber: nil, text: String(line.dropFirst(2))))
            } else {
                diff.lines.append(DiffLine(id: diff.lines.count, kind: .context, oldNumber: old, newNumber: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            }
        }
        return diff
    }

    /// Nombre de carpeta seguro para una rama ("feature/login" → "feature-login").
    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.replacingOccurrences(of: "/", with: "-").unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
    }

    /// Ruta para un worktree nuevo: junto al proyecto, en `<proyecto>.worktrees/<rama>`,
    /// con un sufijo si esa carpeta ya existe.
    public static func worktreePath(for branch: String, projectPath: String,
                                    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let root = URL(fileURLWithPath: projectPath)
        let base = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".worktrees", isDirectory: true)
        let slug = slug(branch)
        var candidate = base.appendingPathComponent(slug).path
        var n = 2
        while exists(candidate) {
            candidate = base.appendingPathComponent("\(slug)-\(n)").path
            n += 1
        }
        return candidate
    }
}
