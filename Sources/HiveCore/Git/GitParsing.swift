import Foundation

/// Dónde se crea la carpeta de un worktree nuevo.
public enum WorktreeLocation: String, Codable, Sendable, CaseIterable {
    /// `<proyecto>.worktrees/<rama>` (el comportamiento de siempre).
    case nested
    /// `<proyecto>-<rama>`, al lado del proyecto (así Herd la sirve sola).
    case sibling
}

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
                        if item == "gone" { status.upstreamGone = true }
                    }
                    header = String(header[..<bracket.lowerBound])
                }
                if header.hasPrefix("No commits yet on ") {
                    status.branch = String(header.dropFirst("No commits yet on ".count))
                    status.isUnborn = true
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

    /// `git status --porcelain=v2 -b -z`: rutas crudas (sin comillas), la ruta original de los
    /// renombres, el commit de HEAD, si el upstream se borró y commits adelante/atrás.
    public static func statusV2(_ text: String) -> GitStatus {
        var status = GitStatus()
        var sawUpstream = false
        var sawAheadBehind = false
        let records = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            if record.hasPrefix("# ") {
                let header = record.dropFirst(2)
                if header.hasPrefix("branch.oid ") {
                    let oid = String(header.dropFirst("branch.oid ".count))
                    if oid == "(initial)" { status.isUnborn = true } else { status.headOid = oid }
                } else if header.hasPrefix("branch.head ") {
                    let head = String(header.dropFirst("branch.head ".count))
                    status.branch = head == "(detached)" ? nil : head
                } else if header.hasPrefix("branch.upstream ") {
                    status.upstream = String(header.dropFirst("branch.upstream ".count))
                    sawUpstream = true
                } else if header.hasPrefix("branch.ab ") {
                    sawAheadBehind = true
                    for part in header.dropFirst("branch.ab ".count).split(separator: " ") {
                        if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                        if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                    }
                }
                continue
            }
            guard let type = record.first else { continue }
            switch type {
            case "1":
                // 1 XY sub mH mI mW hH hI ruta
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                status.changes.append(GitChange(code: v1Code(fields[1]), path: String(fields[8])))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore ruta \0 ruta-original
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let original = i < records.count ? records[i] : nil
                i += 1
                status.changes.append(GitChange(code: v1Code(fields[1]), path: String(fields[9]), originalPath: original))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 ruta
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                status.changes.append(GitChange(code: v1Code(fields[1]), path: String(fields[10])))
            case "?":
                guard record.count > 2 else { continue }
                status.changes.append(GitChange(code: "??", path: String(record.dropFirst(2))))
            default:
                continue // "!" (ignorados) y lo que venga en versiones nuevas
            }
        }
        status.upstreamGone = sawUpstream && !sawAheadBehind
        return status
    }

    /// El XY de v2 usa "." donde v1 usa un espacio.
    private static func v1Code(_ xy: Substring) -> String {
        String(xy.prefix(2).map { $0 == "." ? " " : $0 })
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
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.isPrunable = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.isLocked = true
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// Carpeta de git de un worktree a partir del archivo `.git` ("gitdir: <ruta>"), que puede ser relativa.
    public static func gitDirPointer(_ text: String, relativeTo dir: String) -> String? {
        guard let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let full = path.hasPrefix("/") ? path : (dir as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }

    /// Operación a medio terminar según los archivos que deja git en su carpeta.
    public static func operation(gitDir: String, exists: (String) -> Bool) -> GitOperation? {
        func has(_ name: String) -> Bool { exists((gitDir as NSString).appendingPathComponent(name)) }
        // rebase-apply también lo usa `git am`; en ese caso hay un archivo "applying".
        if has("rebase-merge") || (has("rebase-apply") && !has("rebase-apply/applying")) { return .rebase }
        if has("MERGE_HEAD") { return .merge }
        if has("CHERRY_PICK_HEAD") { return .cherryPick }
        if has("REVERT_HEAD") { return .revert }
        if has("BISECT_LOG") { return .bisect }
        return nil
    }

    /// Rama de `rebase-merge/head-name` ("refs/heads/feat" → "feat").
    public static func rebaseHeadName(_ text: String) -> String? {
        let ref = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.hasPrefix("refs/heads/") else { return nil }
        let name = String(ref.dropFirst("refs/heads/".count))
        return name.isEmpty ? nil : name
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

    /// Diff unificado de un archivo, con números de línea viejos y nuevos. También entiende el
    /// diff combinado de un archivo en conflicto (`diff --cc`, hunks `@@@` y prefijo de dos columnas).
    public static func diff(_ text: String, maxLines: Int = maxDiffLines) -> FileDiff {
        var diff = FileDiff(raw: text)
        var old = 0
        var new = 0
        var inHunk = false
        /// Columnas del prefijo: 1 en un diff común, una por padre en uno combinado.
        var columns = 1
        let rawLines = text.components(separatedBy: "\n")
        for (index, line) in rawLines.enumerated() {
            if diff.lines.count >= maxLines { diff.truncated = true; break }
            if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { diff.isBinary = true; continue }
            if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                inHunk = false
                diff.isCombined = true
                continue
            }
            if line.hasPrefix("diff --git") { inHunk = false; columns = 1; continue }
            if line.hasPrefix("@@@") {
                // @@@ -1,1 -1,1 +1,5 @@@: tantas @ como padres + 1.
                let ats = line.prefix { $0 == "@" }.count
                columns = max(ats - 1, 1)
                let parts = line.split(separator: " ")
                old = parts.count > 1 ? Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0 : 0
                new = parts.first(where: { $0.hasPrefix("+") }).flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
                inHunk = true
                diff.lines.append(DiffLine(id: diff.lines.count, kind: .hunk, oldNumber: nil, newNumber: nil, text: line))
                continue
            }
            if columns > 1 && inHunk {
                if line.isEmpty && index == rawLines.count - 1 { continue }
                if line.hasPrefix("\\") {
                    diff.lines.append(DiffLine(id: diff.lines.count, kind: .note, oldNumber: nil, newNumber: nil, text: String(line.dropFirst(2))))
                    continue
                }
                let prefix = line.prefix(columns)
                let body = String(line.dropFirst(columns))
                if prefix.contains("-") {
                    diff.lines.append(DiffLine(id: diff.lines.count, kind: .removed, oldNumber: prefix.first == "-" ? old : nil, newNumber: nil, text: body))
                    if prefix.first == "-" { old += 1 }
                } else if prefix.contains("+") {
                    let kind: DiffLine.Kind = isConflictMarker(body) ? .conflictMarker : .added
                    diff.lines.append(DiffLine(id: diff.lines.count, kind: kind, oldNumber: nil, newNumber: new, text: body))
                    if prefix.first == " " { old += 1 }
                    new += 1
                } else {
                    diff.lines.append(DiffLine(id: diff.lines.count, kind: .context, oldNumber: old, newNumber: new, text: body))
                    old += 1
                    new += 1
                }
                continue
            }
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

    /// Ruta que git escribió entre comillas con escapes de C (`"con \"comillas\"\303\261"`), sin ellos.
    /// Una ruta sin comillas vuelve tal cual.
    public static func unquotePath(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        let body = Array(text.utf8.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var i = 0
        while i < body.count {
            let c = body[i]
            guard c == UInt8(ascii: "\\"), i + 1 < body.count else {
                bytes.append(c)
                i += 1
                continue
            }
            let next = body[i + 1]
            switch next {
            case UInt8(ascii: "n"): bytes.append(10); i += 2
            case UInt8(ascii: "t"): bytes.append(9); i += 2
            case UInt8(ascii: "r"): bytes.append(13); i += 2
            case UInt8(ascii: "a"): bytes.append(7); i += 2
            case UInt8(ascii: "b"): bytes.append(8); i += 2
            case UInt8(ascii: "f"): bytes.append(12); i += 2
            case UInt8(ascii: "v"): bytes.append(11); i += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Octal de tres dígitos: un byte de UTF-8.
                var value = 0
                var j = i + 1
                while j < body.count, j < i + 4, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(body[j]) {
                    value = value * 8 + Int(body[j] - UInt8(ascii: "0"))
                    j += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                i = j
            default:
                bytes.append(next)
                i += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Líneas que deja git en un archivo en conflicto: <<<<<<<, |||||||, ======= y >>>>>>>.
    public static func isConflictMarker(_ text: String) -> Bool {
        for marker in ["<<<<<<<", ">>>>>>>", "|||||||"] where text.hasPrefix(marker) { return true }
        return text == "=======" || text.hasPrefix("======= ")
    }

    /// Nombre de carpeta seguro para una rama ("feature/login" → "feature-login").
    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.replacingOccurrences(of: "/", with: "-").unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
    }

    /// Prefijos que no aportan al nombre de la carpeta hermana ("feature/checkout" → "checkout").
    static let siblingDroppedPrefixes = ["feature/", "fix/", "chore/"]

    /// Ruta para un worktree nuevo, con un sufijo (-2, -3…) si esa carpeta ya existe.
    /// - `.nested`: en `<proyecto>.worktrees/<rama>`, junto al proyecto.
    /// - `.sibling`: `<proyecto>-<rama>` al lado del proyecto, sin feature/, fix/ ni chore/. Si Herd
    ///   sirve la carpeta padre, el worktree queda servido solo en `<proyecto>-<rama>.test`.
    public static func worktreePath(for branch: String, projectPath: String, style: WorktreeLocation = .nested,
                                    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let root = URL(fileURLWithPath: projectPath)
        let parent = root.deletingLastPathComponent()
        let base: URL
        let name: String
        switch style {
        case .nested:
            base = parent.appendingPathComponent(root.lastPathComponent + ".worktrees", isDirectory: true)
            name = slug(branch)
        case .sibling:
            var short = branch
            for prefix in siblingDroppedPrefixes where short.lowercased().hasPrefix(prefix) && short.count > prefix.count {
                short = String(short.dropFirst(prefix.count))
                break
            }
            base = parent
            name = root.lastPathComponent + "-" + slug(short)
        }
        var candidate = base.appendingPathComponent(name).path
        var n = 2
        while exists(candidate) {
            candidate = base.appendingPathComponent("\(name)-\(n)").path
            n += 1
        }
        return candidate
    }
}
