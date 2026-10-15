import Foundation
import Testing
@testable import HiveCore

@Suite("Repo principal de una carpeta")
struct MainRepoResolverTests {
    @Test("La primera entrada de git worktree list es la carpeta principal")
    func mainRepo() {
        let list = [GitWorktree(path: "/r/app", branch: "main"), GitWorktree(path: "/r/app.worktrees/fix", branch: "fix")]
        #expect(MainRepoResolver.mainRepo(top: "/r/app", worktrees: list).repo == "/r/app")
        #expect(MainRepoResolver.mainRepo(top: "/r/app", worktrees: list).worktree == nil)
        let fromWorktree = MainRepoResolver.mainRepo(top: "/r/app.worktrees/fix/", worktrees: list)
        #expect(fromWorktree.repo == "/r/app")
        #expect(fromWorktree.worktree?.branch == "fix")
        #expect(MainRepoResolver.mainRepo(top: "/r/solo", worktrees: []).repo == "/r/solo")
    }

    @Test("Rama inicial: la actual; con HEAD desacoplado, origin/HEAD, main o master", arguments: [
        ("trunk", nil, ["main"], "trunk"),
        (nil, "origin/develop", ["main"], "develop"),
        (nil, "upstream/release/1.0", [], "release/1.0"),
        (nil, nil, ["feature", "master"], "master"),
        (nil, nil, ["master", "main"], "main"),
        (nil, nil, ["feature"], nil),
        ("", nil, [], nil),
    ] as [(String?, String?, [String], String?)])
    func initialBranch(head: String?, origin: String?, local: [String], expected: String?) {
        #expect(MainRepoResolver.initialBranch(head: head, originHead: origin, localBranches: local) == expected)
    }

    @Test("Con un repo real: la carpeta de un worktree lleva al repo principal")
    func realWorktree() throws {
        let repo = GitRepo()
        let worktree = repo.dir.url.path + "/arreglo"
        repo.sh("git worktree add -q -b arreglo \(shellQuote(worktree))")
        let sub = worktree + "/docs"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)

        let found = try #require(MainRepoResolver.inspect(sub, git: repo.git))
        #expect(found.repo == repo.path)
        #expect(found.head == "main")
        #expect(found.initialBranch == "main")
        #expect(found.worktree?.path == worktree)
        #expect(found.worktree?.branch == "arreglo")
        #expect(found.worktrees.map(\.branch) == ["main", "arreglo"])

        let main = try #require(MainRepoResolver.inspect(repo.path, git: repo.git))
        #expect(main.repo == repo.path && main.worktree == nil)
        #expect(MainRepoResolver.inspect(TempDir().path, git: repo.git) == nil)
    }

    @Test("Con HEAD desacoplado usa origin/HEAD si existe")
    func detachedWithOrigin() throws {
        let repo = GitRepo(branch: "develop")
        _ = repo.addRemote()
        repo.sh("git remote set-head origin develop && git branch main && git checkout -q --detach")
        let found = try #require(MainRepoResolver.inspect(repo.path, git: repo.git))
        #expect(found.head == nil)
        #expect(found.initialBranch == "develop")
        #expect(MainRepoResolver.originHead(repo.path, git: repo.git) == "origin/develop")
    }
}
