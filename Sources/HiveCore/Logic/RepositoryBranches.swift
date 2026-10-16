import Foundation

public struct RepositoryBranches: Equatable, Sendable {
    public var local: [String]
    public var remote: [String]
    public var worktrees: [GitWorktree]

    public init(local: [String], remote: [String], worktrees: [GitWorktree]) {
        self.local = local
        self.remote = remote
        self.worktrees = worktrees
    }

    public var withoutWorktree: [String] {
        let checkedOut = Set(worktrees.filter { !$0.isPrunable }.compactMap(\.branch))
        return local.filter { !checkedOut.contains($0) }
    }

    public var remoteOnly: [String] {
        remote.filter { ref in
            guard let slash = ref.firstIndex(of: "/") else { return false }
            return !local.contains(String(ref[ref.index(after: slash)...])) && !ref.hasSuffix("/HEAD")
        }
    }
}
