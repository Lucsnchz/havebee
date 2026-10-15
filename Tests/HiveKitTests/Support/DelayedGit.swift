import Foundation
import HiveCore

/// git real con demoras configurables por operación. Lee primero y espera después, así una
/// revisión lenta devuelve lo que había al empezar (como pasa cuando git tarda de verdad).
final class DelayedGit: GitClient, @unchecked Sendable {
    enum Operation: Hashable {
        case topLevel, currentBranch, worktrees, status
    }

    private let base = GitCLI()
    private let lock = NSLock()
    private var delays: [Operation: TimeInterval] = [:]
    private var counts: [Operation: Int] = [:]

    func setDelay(_ operation: Operation, _ seconds: TimeInterval) {
        lock.withLock { delays[operation] = seconds }
    }

    /// Cuántas veces se llamó una operación.
    func calls(_ operation: Operation) -> Int {
        lock.withLock { counts[operation] ?? 0 }
    }

    private func slow<T>(_ operation: Operation, _ body: () -> T) -> T {
        let result = body()
        let delay = lock.withLock { () -> TimeInterval in
            counts[operation, default: 0] += 1
            return delays[operation] ?? 0
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return result
    }

    func topLevel(_ dir: String) -> String? { slow(.topLevel) { base.topLevel(dir) } }
    func currentBranch(_ dir: String) -> String? { slow(.currentBranch) { base.currentBranch(dir) } }
    func worktrees(_ dir: String) -> [GitWorktree] { slow(.worktrees) { base.worktrees(dir) } }
    func status(_ dir: String) -> GitStatus? { slow(.status) { base.status(dir) } }

    func localBranches(_ dir: String) -> [String] { base.localBranches(dir) }
    func remoteBranches(_ dir: String) -> [String] { base.remoteBranches(dir) }
    func recentCommits(_ dir: String, limit: Int) -> [GitCommit] { base.recentCommits(dir, limit: limit) }
    func diff(for change: GitChange, staged: Bool, in dir: String) -> FileDiff { base.diff(for: change, staged: staged, in: dir) }
    func isValidBranchName(_ name: String, in dir: String) -> Bool { base.isValidBranchName(name, in: dir) }
    func initRepository(_ dir: String) -> CommandResult { base.initRepository(dir) }
    func createBranch(_ name: String, from base: String, in dir: String) -> CommandResult {
        self.base.createBranch(name, from: base, in: dir)
    }
    func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, in dir: String) -> CommandResult {
        self.base.addWorktree(at: path, branch: branch, newBranch: newBranch, base: base, in: dir)
    }
    func removeWorktree(_ path: String, force: Bool, in dir: String) -> CommandResult { base.removeWorktree(path, force: force, in: dir) }
    func checkout(_ branch: String, in dir: String) -> CommandResult { base.checkout(branch, in: dir) }
}
