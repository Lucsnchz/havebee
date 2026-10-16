import Foundation

/// Archivos que git ignora pero que un worktree nuevo necesita para funcionar: .env, auth.json,
/// los permisos de Claude, local.properties… Se eligen con `.worktreeinclude` (el mismo archivo
/// que usan Claude Code y Conductor, con sintaxis de .gitignore) o con una lista de fábrica.
public enum WorktreeIncludes {
    public static let fileName = ".worktreeinclude"

    public static let defaultPatterns = [
        ".env", ".env.*", "auth.json", ".mcp.json", ".claude/settings.local.json",
        "local.properties", "keystore.properties", "*.jks", "*.keystore",
    ]

    /// Carpetas pesadas en las que no se busca.
    public static let skippedFolders: Set<String> = ["node_modules", "vendor", "build", ".git"]

    /// Acceso al disco. Se inyecta en los tests.
    public struct FileSystem: Sendable {
        public var read: @Sendable (String) -> String?
        /// Archivos debajo de una carpeta (rutas relativas), sin entrar en las carpetas salteadas.
        public var files: @Sendable (_ root: String, _ skipping: Set<String>) -> [String]
        public var exists: @Sendable (String) -> Bool
        /// Copia un archivo creando las carpetas que falten.
        public var copy: @Sendable (_ from: String, _ to: String) throws -> Void
        public var write: @Sendable (_ text: String, _ path: String) throws -> Void

        public init(read: @escaping @Sendable (String) -> String?,
                    files: @escaping @Sendable (String, Set<String>) -> [String],
                    exists: @escaping @Sendable (String) -> Bool,
                    copy: @escaping @Sendable (String, String) throws -> Void,
                    write: @escaping @Sendable (String, String) throws -> Void) {
            self.read = read
            self.files = files
            self.exists = exists
            self.copy = copy
            self.write = write
        }

        public static let live = FileSystem(
            read: { try? String(contentsOfFile: $0, encoding: .utf8) },
            files: { root, skipping in liveFiles(root: root, skipping: skipping) },
            exists: { FileManager.default.fileExists(atPath: $0) },
            copy: { from, to in
                let folder = (to as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                // En APFS, copyItem hace un clon: no ocupa espacio extra.
                try FileManager.default.copyItem(atPath: from, toPath: to)
            },
            write: { text, path in try text.write(toFile: path, atomically: true, encoding: .utf8) })

        /// Recorre la carpeta sin seguir enlaces y con un tope, para no tardar en repos enormes. Va por
        /// niveles: si se llega al tope en una carpeta gigante (storage, .next…), los archivos de arriba,
        /// como el .env de la raíz, ya se encontraron. No entra en otro repo ni en otro worktree (una
        /// subcarpeta con su propio .git, como los de Claude Code en .claude/worktrees o un submódulo):
        /// sus .env no son de este proyecto.
        static func liveFiles(root: String, skipping: Set<String>, limit: Int = 50_000) -> [String] {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            var queue: [(url: URL, relative: String)] = [(URL(fileURLWithPath: root, isDirectory: true), "")]
            var result: [String] = []
            var seen = 0
            var next = 0
            while next < queue.count && seen < limit {
                let folder = queue[next]
                next += 1
                guard let entries = try? FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: keys) else { continue }
                for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    seen += 1
                    if seen > limit { break }
                    let name = url.lastPathComponent
                    let relative = folder.relative.isEmpty ? name : folder.relative + "/" + name
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    if values?.isSymbolicLink == true { continue }
                    if values?.isDirectory == true {
                        let nestedRepo = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
                        if !skipping.contains(name) && !nestedRepo { queue.append((url, relative)) }
                    } else if values?.isRegularFile == true {
                        result.append(relative)
                    }
                }
            }
            return result.sorted()
        }
    }

    /// Patrones de `.worktreeinclude` (sin comentarios ni líneas vacías).
    public static func parsePatterns(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Los patrones del repo o, si no tiene `.worktreeinclude`, los de fábrica.
    public static func patterns(root: String, fileSystem: FileSystem = .live) -> [String] {
        guard let text = fileSystem.read((root as NSString).appendingPathComponent(fileName)) else { return defaultPatterns }
        return parsePatterns(text)
    }

    /// Si la ruta (relativa) entra en la lista. Como en .gitignore: un patrón sin «/» vale en
    /// cualquier nivel, con «/» se ancla a la raíz, «dir/» incluye todo lo de adentro y «!» excluye.
    public static func includes(_ relativePath: String, patterns: [String]) -> Bool {
        var included = false
        for raw in patterns {
            let negated = raw.hasPrefix("!")
            let pattern = negated ? String(raw.dropFirst()) : raw
            if matches(relativePath, pattern: pattern) { included = !negated }
        }
        return included
    }

    static func matches(_ path: String, pattern rawPattern: String) -> Bool {
        var pattern = rawPattern
        let onlyFolders = pattern.hasSuffix("/")
        if onlyFolders { pattern.removeLast() }
        guard !pattern.isEmpty else { return false }
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        let components = path.split(separator: "/").map(String.init)
        // Prefijos de la ruta: carpetas que la contienen y, si no es «solo carpetas», el archivo.
        let count = onlyFolders ? components.count - 1 : components.count
        guard count > 0 else { return false }
        for end in 1...count {
            let candidate = anchored ? components[0..<end].joined(separator: "/") : components[end - 1]
            if glob(pattern, candidate) { return true }
        }
        return false
    }

    private static func glob(_ pattern: String, _ text: String) -> Bool {
        // «**» cruza carpetas; el resto de los comodines no.
        let flags = pattern.contains("**") ? 0 : FNM_PATHNAME
        return fnmatch(pattern.replacingOccurrences(of: "**/", with: "*"), text, flags) == 0
            || fnmatch(pattern, text, flags) == 0
    }

    /// Archivos del repo que entran en los patrones (tengan o no seguimiento).
    public static func candidates(root: String, patterns: [String], fileSystem: FileSystem = .live) -> [String] {
        fileSystem.files(root, skippedFolders).filter { includes($0, patterns: patterns) }
    }

    /// Los candidatos que git ignora: nunca se duplica un archivo con seguimiento.
    public static func files(in root: String, git: GitClient, fileSystem: FileSystem = .live) -> [String] {
        let found = candidates(root: root, patterns: patterns(root: root, fileSystem: fileSystem), fileSystem: fileSystem)
        guard !found.isEmpty else { return [] }
        let ignored = Set(git.ignored(paths: found, in: root))
        return found.filter(ignored.contains)
    }

    /// Copia los archivos a otra carpeta sin pisar nada. Devuelve los que copió.
    public static func copy(_ files: [String], from root: String, to destination: String, fileSystem: FileSystem = .live) -> [String] {
        var copied: [String] = []
        for file in files {
            let target = (destination as NSString).appendingPathComponent(file)
            guard !fileSystem.exists(target) else { continue }
            do {
                try fileSystem.copy((root as NSString).appendingPathComponent(file), target)
                copied.append(file)
            } catch {
                continue
            }
        }
        return copied
    }

    /// Texto corto para avisar qué se copió: «.env, auth.json y 2 más».
    public static func summary(_ files: [String], shown: Int = 2) -> String {
        let names = files.map { $0 == ".claude/settings.local.json" ? "permisos de Claude" : $0 }
        guard !names.isEmpty else { return "" }
        if names.count <= shown + 1 {
            return names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " y " + names[names.count - 1]
        }
        return names.prefix(shown).joined(separator: ", ") + " y \(names.count - shown) más"
    }
}
