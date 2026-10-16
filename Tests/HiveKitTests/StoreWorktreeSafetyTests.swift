import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

@MainActor
@Suite("Worktrees: cierre seguro y preparación")
struct StoreWorktreeSafetyTests {
    func setup(_ repo: GitRepo, world: TestWorld, branch: String = "feature") async throws -> (AppStore, Project, Branch) {
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.createBranch(.init(projectId: project.id, name: branch, isNew: true, mode: .worktree)) == nil)
        return (store, project, try #require(store.project(project.id)?.branches.first { $0.name == branch }))
    }

    @Test("Conservar la rama permite recrear su worktree desde el resumen")
    func preserveAndRecreate() async throws {
        let repo = GitRepo(), world = TestWorld()
        let (store, project, branch) = try await setup(repo, world: world)
        let review = try #require(await store.removalReview(branchId: branch.id))
        #expect(await store.performRemove(.branch(branch.id), deleteWorktree: true, review: review))
        #expect(repo.git.localBranches(repo.path).contains("feature"))
        await store.refreshGitNow()
        #expect(store.repositoryBranches[project.id]?.withoutWorktree.contains("feature") == true)
        #expect(await store.createBranch(.init(projectId: project.id, name: "feature", isNew: false, mode: .worktree)) == nil)
        #expect(repo.git.worktrees(repo.path).contains { $0.branch == "feature" })
    }

    @Test("Commits sin integrar: exige el nombre exacto; la rama remota se conserva")
    func unmergedBranchRequiresName() async throws {
        let repo = GitRepo(), world = TestWorld()
        _ = repo.addRemote()
        let (store, _, branch) = try await setup(repo, world: world)
        let path = try #require(branch.worktreePath)
        #expect(repo.sh("git commit --allow-empty -m pendiente", in: path).ok)
        #expect(repo.sh("git push origin feature", in: path).ok)
        let review = try #require(await store.removalReview(branchId: branch.id))
        #expect(review.unmergedCount == 1)
        #expect(review.needsTypedName(deleteBranch: true))
        #expect(!(await store.performRemove(.branch(branch.id), deleteWorktree: true, deleteBranch: true, review: review, confirmation: "Feature")))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(await store.performRemove(.branch(branch.id), deleteWorktree: true, deleteBranch: true, review: review, confirmation: "feature"))
        #expect(!repo.git.localBranches(repo.path).contains("feature"))
        #expect(repo.git.remoteBranches(repo.path).contains("origin/feature"))
    }

    @Test("Archivos sin commit no se borran por una confirmación vieja ni por force sin nombre")
    func dirtyAndStaleReview() async throws {
        let repo = GitRepo(), world = TestWorld()
        let (store, _, branch) = try await setup(repo, world: world)
        let path = try #require(branch.worktreePath)
        let before = try #require(await store.removalReview(branchId: branch.id))
        try "trabajo sin guardar".write(toFile: path + "/nuevo.txt", atomically: true, encoding: .utf8)
        #expect(!(await store.performRemove(.branch(branch.id), deleteWorktree: true, review: before)))
        #expect(!(await store.performRemove(.branch(branch.id), deleteWorktree: true, force: true)))
        let review = try #require(await store.removalReview(branchId: branch.id))
        #expect(review.needsForce)
        #expect(await store.performRemove(.branch(branch.id), deleteWorktree: true, force: true, review: review, confirmation: "feature"))
        #expect(repo.git.localBranches(repo.path).contains("feature"))
    }

    @Test("Un commit nuevo invalida la revisión; main y el checkout principal están protegidos")
    func changedTipAndProtectedBranch() async throws {
        let repo = GitRepo(), world = TestWorld()
        let (store, _, branch) = try await setup(repo, world: world)
        let path = try #require(branch.worktreePath)
        let before = try #require(await store.removalReview(branchId: branch.id))
        #expect(repo.sh("git commit --allow-empty -m nuevo", in: path).ok)
        #expect(!(await store.performRemove(.branch(branch.id), deleteWorktree: true, deleteBranch: true, review: before, confirmation: "feature")))
        #expect(FileManager.default.fileExists(atPath: path))
        let main = WorktreeRemovalReview.inspect(branch: "main", path: repo.path, repo: repo.path, git: repo.git)
        #expect(main.protectedBranch && !main.canDeleteBranch && !main.valid)
        #expect(!repo.git.deleteBranch("feature", expectedTip: try #require(before.tip), force: true, in: repo.path).ok)
    }

    @Test("La IA espera al setup; un error conserva la preparación y permite reintentar")
    func setupBlocksAgentUntilSuccess() async throws {
        let repo = GitRepo(), world = TestWorld()
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.createBranch(.init(projectId: project.id, name: "ready", isNew: true, mode: .worktree,
                                               firstSession: .claude, setupCommand: "composer install")) == nil)
        let branch = try #require(store.project(project.id)?.branches.first { $0.name == "ready" })
        let run = try #require(store.commandRuns.first)
        #expect(branch.sessions.isEmpty)
        store.requestNewSession(branchId: branch.id, kind: .codex)
        #expect(store.branchContext(branch.id)?.branch.sessions.isEmpty == true)
        store.commandExited(run.id, terminal: try #require(run.terminal), code: 1)
        #expect(store.branchContext(branch.id)?.branch.setupCommand != nil)
        #expect(store.branchContext(branch.id)?.branch.sessions.isEmpty == true)
        store.retryPreparation(branch.id)
        store.commandExited(run.id, terminal: try #require(run.terminal), code: 0)
        #expect(store.branchContext(branch.id)?.branch.setupCommand == nil)
        #expect(store.branchContext(branch.id)?.branch.sessions.map(\.kind) == [.claude])
    }

    @Test("Convierte una rama ya agregada a Hive sin perder sesiones")
    func existingHiveBranch() async throws {
        let repo = GitRepo(), world = TestWorld()
        #expect(repo.git.createBranch("existing", from: "main", in: repo.path).ok)
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.createBranch(.init(projectId: project.id, name: "existing", isNew: false, mode: .main)) == nil)
        let branch = try #require(store.project(project.id)?.branches.first { $0.name == "existing" })
        let session = Session(name: "Historial", kind: .claude)
        store.projects.updateBranch(branch.id) { $0.sessions = [session] }
        #expect(await store.createBranch(.init(projectId: project.id, name: "existing", isNew: false, mode: .worktree)) == nil)
        let converted = try #require(store.branchContext(branch.id)?.branch)
        #expect(converted.mode == .worktree && converted.sessions == [session])
    }

    @Test("Un worktree bloqueado pide confirmación; una base desconocida nunca figura como integrada")
    func lockedAndUnknownBase() async throws {
        let repo = GitRepo(branch: "trunk"), world = TestWorld()
        let (store, _, branch) = try await setup(repo, world: world)
        let path = try #require(branch.worktreePath)
        #expect(repo.sh("git worktree lock \(shellQuote(path))").ok)
        let review = try #require(await store.removalReview(branchId: branch.id))
        #expect(review.locked && review.needsForce)
        #expect(review.unmergedCount == nil)
        #expect(review.mergeSummary.contains("No pude comprobar"))
        #expect(await store.performRemove(.branch(branch.id), deleteWorktree: true, force: true, review: review, confirmation: "feature"))
        #expect(repo.git.localBranches(repo.path).contains("feature"))
    }

    @Test("Rama solo remota: el resumen la ofrece y el worktree sigue ese remoto")
    func remoteBranch() async throws {
        let repo = GitRepo(), world = TestWorld()
        _ = repo.addRemote()
        #expect(repo.sh("git branch pendiente && git push origin pendiente && git branch -D pendiente").ok)
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        await store.refreshGitNow()
        #expect(store.repositoryBranches[project.id]?.remoteOnly == ["origin/pendiente"])
        #expect(await store.createBranch(.init(projectId: project.id, name: "pendiente", isNew: false, mode: .worktree,
                                               remoteRef: "origin/pendiente")) == nil)
        let branch = try #require(store.project(project.id)?.branches.first { $0.name == "pendiente" })
        #expect(repo.git.status(try #require(branch.worktreePath))?.upstream == "origin/pendiente")
    }

    @Test("Hojas y resumen con ramas disponibles, en claro y oscuro")
    func worktreeScreens() async throws {
        let repo = GitRepo(), world = TestWorld(), defaults = SnapshotDefaults()
        repo.write("artisan", "<?php")
        repo.write("composer.json", "{}")
        repo.write(".env.example", "APP_KEY=\n")
        repo.commit("Laravel")
        let (store, project, branch) = try await setup(repo, world: world)
        #expect(repo.git.createBranch("fix/pagos", from: "main", in: repo.path).ok)
        let tree = try #require(branch.worktreePath)
        #expect(repo.sh("git commit --allow-empty -m 'Trabajo pendiente'", in: tree).ok)
        try "cambios sin guardar".write(toFile: tree + "/pago.php", atomically: true, encoding: .utf8)
        await store.refreshGitNow()
        store.requestRemoval(.branch(branch.id))
        let removal = try #require(store.pendingRemoval)
        let screens: [(String, AnyView, CGSize)] = [
            ("worktrees-resumen", AnyView(NavigationStack { ProjectDetailView(projectId: project.id) }), .init(width: 900, height: 900)),
            ("worktrees-nuevo", AnyView(NewBranchSheet(projectId: project.id, initialBranch: "fix/pagos")), .init(width: 540, height: 800)),
            ("worktrees-cierre", AnyView(WorktreeRemovalSheet(removal: removal)), .init(width: 640, height: 750))
        ]
        for (name, view, size) in screens {
            let images = await Snapshot.render(view.environment(store), size: size, name: name, defaults: defaults.defaults, settle: 0.8)
            #expect(images.count == 2)
        }
    }
}
