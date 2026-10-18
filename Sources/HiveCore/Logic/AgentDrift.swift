import Foundation

/// La rama donde trabaja de verdad el agente de una sesión, cuando no es la suya en Hive: arrancó en
/// `main` y se pasó a otro worktree del proyecto (con `cd` o EnterWorktree), o hizo checkout de otra
/// rama en la carpeta principal. La sesión sigue en su rama (ahí se relanza y se reanuda); esto es lo
/// que muestran su pestaña, su barra de estado y sus cambios.
public struct AgentDrift: Equatable, Sendable {
    /// La rama en la que trabaja ahora.
    public let branchName: String
    /// La carpeta de esa rama (la de su worktree o la principal), tal como la guarda el proyecto.
    public let directory: String

    public init(branchName: String, directory: String) {
        self.branchName = branchName
        self.directory = directory
    }

    /// Dónde trabaja el agente, si no es en `branch`. `cwd` es la carpeta que informó el agente (nil
    /// mientras no dijo nada: se toma la de la rama) y `head`, la rama de la carpeta principal.
    /// Una carpeta fuera del proyecto no cuenta: el agente puede asomarse a otra y volver.
    public static func of(_ branch: Branch, in project: Project, cwd: String?, head: String?) -> AgentDrift? {
        guard !project.isScratch else { return nil }
        let dir = normalized(cwd ?? project.directory(for: branch))
        // La carpeta más específica que la contiene: un worktree puede estar adentro de la principal
        // (los de Claude van en .claude/worktrees).
        var folders: [(key: String, path: String, worktree: Branch?)] = project.branches.compactMap { b in
            guard b.mode == .worktree, let path = b.worktreePath else { return nil }
            return (normalized(path), path, b)
        }
        folders.append((normalized(project.path), project.path, nil))
        guard let folder = folders.filter({ dir == $0.key || dir.hasPrefix($0.key + "/") })
            .max(by: { $0.key.count < $1.key.count }) else { return nil }
        if let worktree = folder.worktree {
            return worktree.id == branch.id ? nil : AgentDrift(branchName: worktree.name, directory: folder.path)
        }
        // En la carpeta principal, la rama es la que tiene checkout.
        guard let head, !head.isEmpty, branch.mode == .worktree || head != branch.name else { return nil }
        return AgentDrift(branchName: head, directory: folder.path)
    }

    /// Sin `.`, `..` ni barra final, y sin mirar el disco: se calcula al dibujar cada pestaña.
    /// (`standardizedFileURL` saca el /private solo si la carpeta existe, y una subcarpeta recién
    /// nombrada dejaba de coincidir con su worktree).
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        // /tmp y /var son enlaces a /private/…: un agente puede informar cualquiera de las dos.
        if parts.count > 1, parts[0] == "private", ["tmp", "var", "etc"].contains(parts[1]) { parts.removeFirst() }
        return "/" + parts.joined(separator: "/")
    }
}
