import Foundation
import Testing
@testable import HiveCore

/// Un GitClient que no es GitCLI (como los de los tests de la app): delega en git real salvo la
/// rama por defecto del remoto, que es fija.
private struct FinalRemoteGit: GitClient {
    let base = GitCLI()
    let remoteDefault: String?

    func topLevel(_ dir: String) -> String? { base.topLevel(dir) }
    func currentBranch(_ dir: String) -> String? { base.currentBranch(dir) }
    func localBranches(_ dir: String) -> [String] { base.localBranches(dir) }
    func remoteBranches(_ dir: String) -> [String] { base.remoteBranches(dir) }
    func worktrees(_ dir: String) -> [GitWorktree] { base.worktrees(dir) }
    func status(_ dir: String) -> GitStatus? { base.status(dir) }
    func recentCommits(_ dir: String, limit: Int) -> [GitCommit] { base.recentCommits(dir, limit: limit) }
    func diff(for change: GitChange, staged: Bool, in dir: String) -> FileDiff { base.diff(for: change, staged: staged, in: dir) }
    func isValidBranchName(_ name: String, in dir: String) -> Bool { base.isValidBranchName(name, in: dir) }
    func initRepository(_ dir: String) -> CommandResult { base.initRepository(dir) }
    func createBranch(_ name: String, from base: String, in dir: String) -> CommandResult { self.base.createBranch(name, from: base, in: dir) }
    func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, in dir: String) -> CommandResult {
        self.base.addWorktree(at: path, branch: branch, newBranch: newBranch, base: base, in: dir)
    }
    func removeWorktree(_ path: String, force: Bool, in dir: String) -> CommandResult { base.removeWorktree(path, force: force, in: dir) }
    func checkout(_ branch: String, in dir: String) -> CommandResult { base.checkout(branch, in: dir) }
    func defaultRemoteBranch(_ dir: String) -> String? { remoteDefault }
}

@Suite("Integración final (núcleo)")
struct IntegracionFinalCoreTests {
    @Test("Con HEAD desacoplado, la rama inicial sale del GitClient aunque no sea el git del sistema")
    func detachedHeadUsesClient() throws {
        let repo = GitRepo(branch: "feature")
        repo.sh("git checkout -q --detach")
        let client = FinalRemoteGit(remoteDefault: "upstream/trunk")
        #expect(MainRepoResolver.originHead(repo.path, git: client) == "upstream/trunk")
        let found = try #require(MainRepoResolver.inspect(repo.path, git: client))
        #expect(found.head == nil)
        #expect(found.initialBranch == "trunk")
        // Sin remoto ni main/master no se inventa una rama «HEAD».
        let none = try #require(MainRepoResolver.inspect(repo.path, git: FinalRemoteGit(remoteDefault: nil)))
        #expect(none.initialBranch == nil)
    }
}
