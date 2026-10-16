import Foundation

/// Estado que vio la persona antes de confirmar. Se compara otra vez después de detener los procesos.
public struct WorktreeRemovalReview: Equatable, Sendable {
    public var branch: String
    public var tip: String?
    public var base: String?
    public var baseTip: String?
    public var unmergedCount: Int?
    public var changes: [GitChange]
    public var operation: GitOperation?
    public var locked: Bool
    public var valid: Bool
    public var protectedBranch: Bool

    public var needsForce: Bool { !changes.isEmpty || locked }
    public var canDeleteBranch: Bool { valid && tip != nil && !protectedBranch && operation == nil }
    public func needsTypedName(deleteBranch: Bool) -> Bool { deleteBranch || needsForce }

    public static func inspect(branch: String, path: String, repo: String, git: GitClient) -> Self {
        let trees = git.worktrees(repo)
        let entry = trees.first { samePath($0.path, path) }
        let status = git.status(path)
        let local = git.localBranches(repo)
        let remote = git.remoteBranches(repo)
        let defaultRemote = git.defaultRemoteBranch(repo)
        let defaultName = defaultRemote.flatMap { ref in ref.firstIndex(of: "/").map { String(ref[ref.index(after: $0)...]) } }
        let base: String?
        if local.contains("main") { base = "refs/heads/main" }
        else if remote.contains("origin/main") { base = "refs/remotes/origin/main" }
        else if let defaultRemote { base = "refs/remotes/" + defaultRemote }
        else if local.contains("master") { base = "refs/heads/master" }
        else { base = nil }
        let isMissing = !FileManager.default.fileExists(atPath: path)
        return Self(branch: branch, tip: git.revision("refs/heads/" + branch, in: repo), base: base,
                    baseTip: base.flatMap { git.revision($0, in: repo) },
                    unmergedCount: base.flatMap { git.commitsNotMerged(branch: branch, into: $0, in: repo) },
                    changes: status?.changes ?? [], operation: status?.operation, locked: entry?.isLocked == true,
                    valid: !samePath(path, repo) && (entry?.branch == branch || (entry == nil && isMissing))
                        && (isMissing || (status != nil && status?.branch == branch)),
                    protectedBranch: ["main", "master", defaultName].compactMap { $0 }.contains(branch))
    }

    public var baseLabel: String { base?.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "") ?? "main" }

    public var mergeSummary: String {
        if let unmergedCount {
            return unmergedCount == 0 ? "Todos los commits están integrados en \(baseLabel)."
                : "\(unmergedCount) \(unmergedCount == 1 ? "commit sin integrar" : "commits sin integrar") en \(baseLabel). Si borrás la rama podés perder ese trabajo."
        }
        return "No pude comprobar si está integrada en main. Borrar la rama puede dejar commits sin una referencia."
    }
}
