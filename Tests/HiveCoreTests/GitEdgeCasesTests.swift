import Foundation
import Testing
@testable import HiveCore

/// Casos raros de git con repos reales en carpetas temporales.
@Suite("Git: casos raros (repos reales)")
struct GitEdgeCasesTests {
    func project(_ repo: GitRepo, branches: [Branch] = [Branch(name: "main", mode: .main)]) -> Project {
        Project(name: "repo", path: repo.path, branches: branches)
    }

    /// Upstream de una rama, o nil si no sigue a ninguna.
    func upstream(_ repo: GitRepo, _ branch: String, in dir: String? = nil) -> String? {
        let r = repo.sh("git rev-parse --abbrev-ref \(shellQuote(branch + "@{u}"))", in: dir)
        return r.ok ? r.output : nil
    }

    @Test("Una rama remota que se llama como una carpeta («docs») se puede usar")
    func branchNamedLikeFolder() throws {
        let repo = GitRepo()
        repo.write("docs/index.md", "# Docs\n")
        repo.commit("Docs")
        _ = repo.addRemote()
        repo.sh("git branch docs && git push -q origin docs 2>/dev/null && git branch -q -D docs")
        // checkout con git switch: crea la local siguiendo origin/docs, sin confundirla con la carpeta.
        let r = repo.git.checkout("docs", in: repo.path)
        #expect(r.ok, "\(r.errorMessage)")
        #expect(repo.git.currentBranch(repo.path) == "docs")
        #expect(upstream(repo, "docs") == "origin/docs")
    }

    @Test("Con dos remotos se usa el elegido, en worktree y en la carpeta principal")
    func twoRemotes() throws {
        let repo = GitRepo()
        _ = repo.addRemote()
        let other = repo.dir.subdir("upstream.git").path
        repo.sh("git init -q --bare \(shellQuote(other)) && git remote add upstream \(shellQuote(other))")
        repo.sh("git branch dos && git push -q origin dos 2>/dev/null && git push -q upstream dos 2>/dev/null")
        repo.sh("git branch tres && git push -q origin tres 2>/dev/null && git push -q upstream tres 2>/dev/null")
        repo.sh("git branch -q -D dos tres && git fetch -q --all")
        #expect(Set(repo.git.remoteBranches(repo.path)).isSuperset(of: ["origin/dos", "upstream/dos"]))

        let request = NewBranchRequest(projectId: UUID(), name: "dos", isNew: false, mode: .worktree, remoteRef: "upstream/dos")
        let worktree = try BranchPlanner.prepare(request, project: project(repo), git: repo.git).get()
        let path = try #require(worktree.worktreePath)
        #expect(repo.git.currentBranch(path) == "dos")
        #expect(upstream(repo, "dos", in: path) == "upstream/dos")

        let main = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "tres", isNew: false, mode: .main, remoteRef: "upstream/tres"),
                                             project: project(repo), git: repo.git).get()
        #expect(main.mode == .main)
        #expect(upstream(repo, "tres") == "upstream/tres")
        #expect(repo.git.checkout("tres", in: repo.path).ok)
    }

    @Test("Partir de origin/main no deja origin/main como upstream (--no-track)")
    func noTrackFromRemoteBase() throws {
        let repo = GitRepo()
        _ = repo.addRemote()
        repo.sh("git fetch -q origin")
        let worktree = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "desde-remoto", isNew: true, base: "origin/main", mode: .worktree),
                                                 project: project(repo), git: repo.git).get()
        #expect(upstream(repo, "desde-remoto", in: worktree.worktreePath) == nil)
        _ = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "en-principal", isNew: true, base: "origin/main", mode: .main),
                                      project: project(repo), git: repo.git).get()
        #expect(upstream(repo, "en-principal") == nil)
        #expect(repo.git.defaultRemoteBranch(repo.path) == "origin/main")
    }

    @Test("Un worktree borrado con rm -rf no se adopta: se poda y se crea de nuevo")
    func prunableWorktree() throws {
        let repo = GitRepo()
        let gone = repo.dir.url.path + "/borrado"
        repo.sh("git worktree add -q -b vieja \(shellQuote(gone))")
        try FileManager.default.removeItem(atPath: gone)
        let listed = repo.git.worktrees(repo.path)
        #expect(listed.contains { $0.branch == "vieja" && $0.isPrunable })
        // WorktreeSync no la suma (aunque el «exists» diga que sí).
        #expect(WorktreeSync.apply(listed, to: project(repo), exists: { _ in true }) == nil)

        let branch = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "vieja", isNew: false, mode: .worktree),
                                               project: project(repo), git: repo.git).get()
        let path = try #require(branch.worktreePath)
        #expect(!samePath(path, gone))
        #expect(FileManager.default.fileExists(atPath: path + "/README.md"))
        #expect(!repo.git.worktrees(repo.path).contains { $0.isPrunable })
    }

    @Test("Una rama nueva cuyo destino es un worktree podado se crea igual")
    func prunableTarget() throws {
        let repo = GitRepo()
        let target = GitParsing.worktreePath(for: "nueva", projectPath: repo.path)
        repo.sh("git worktree add -q -b otra \(shellQuote(target))")
        try FileManager.default.removeItem(atPath: target)
        let branch = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "nueva", isNew: true, base: "main", mode: .worktree),
                                               project: project(repo), git: repo.git).get()
        #expect(samePath(try #require(branch.worktreePath), target))
        #expect(repo.git.currentBranch(target) == "nueva")
    }

    @Test("Olvidar un worktree faltante no se lleva a otro que está en un disco desconectado")
    func missingWorktreeKeepsOthers() throws {
        let repo = GitRepo()
        let gone = repo.dir.url.path + "/borrado-a"
        let unplugged = repo.dir.url.path + "/disco-b"
        repo.sh("git worktree add -q -b a \(shellQuote(gone)) && git worktree add -q -b b \(shellQuote(unplugged))")
        try FileManager.default.removeItem(atPath: gone)
        try FileManager.default.removeItem(atPath: unplugged) // B «desconectado», sin lock
        let removed = repo.git.removeWorktree(gone, force: false, in: repo.path)
        #expect(removed.ok, "\(removed.errorMessage)")
        let listed = repo.git.worktrees(repo.path)
        #expect(!listed.contains { $0.branch == "a" })
        #expect(listed.contains { $0.branch == "b" && samePath($0.path, unplugged) })
        // Ya olvidado: quitarlo otra vez no es un error.
        #expect(repo.git.removeWorktree(gone, force: false, in: repo.path).ok)

        // Una rama nueva cuyo destino estaba registrado olvida solo esa entrada.
        let target = GitParsing.worktreePath(for: "nueva", projectPath: repo.path)
        repo.sh("git worktree add -q -b vieja \(shellQuote(target))")
        try FileManager.default.removeItem(atPath: target)
        let branch = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "nueva", isNew: true, base: "main", mode: .worktree),
                                               project: project(repo), git: repo.git).get()
        #expect(samePath(try #require(branch.worktreePath), target))
        #expect(repo.git.worktrees(repo.path).contains { $0.branch == "b" && samePath($0.path, unplugged) })
    }

    @Test("Un worktree bloqueado se borra con «Borrar igual»; uno que ya no existe se olvida")
    func lockedAndMissing() throws {
        let repo = GitRepo()
        let locked = repo.dir.url.path + "/bloqueado"
        repo.sh("git worktree add -q -b bloqueada \(shellQuote(locked)) && git worktree lock \(shellQuote(locked))")
        #expect(repo.git.worktrees(repo.path).contains { $0.isLocked && samePath($0.path, locked) })
        #expect(!repo.git.removeWorktree(locked, force: false, in: repo.path).ok)
        let forced = repo.git.removeWorktree(locked, force: true, in: repo.path)
        #expect(forced.ok, "\(forced.errorMessage)")
        #expect(!FileManager.default.fileExists(atPath: locked))

        let missing = repo.dir.url.path + "/desaparecido"
        repo.sh("git worktree add -q -b desaparecida \(shellQuote(missing))")
        try FileManager.default.removeItem(atPath: missing)
        #expect(repo.git.removeWorktree(missing, force: false, in: repo.path).ok)
        #expect(!repo.git.worktrees(repo.path).contains { $0.branch == "desaparecida" })

        // Bloqueado y sin carpeta (un disco desconectado): prune no lo toca, así que sin forzar avisa y
        // con «Borrar igual» se olvida de verdad.
        let unplugged = repo.dir.url.path + "/desenchufado"
        repo.sh("git worktree add -q -b desenchufada \(shellQuote(unplugged)) && git worktree lock \(shellQuote(unplugged))")
        try FileManager.default.removeItem(atPath: unplugged)
        let refused = repo.git.removeWorktree(unplugged, force: false, in: repo.path)
        #expect(!refused.ok && refused.errorMessage.contains("bloqueado"))
        #expect(repo.git.worktrees(repo.path).contains { $0.branch == "desenchufada" })
        let gone = repo.git.removeWorktree(unplugged, force: true, in: repo.path)
        #expect(gone.ok, "\(gone.errorMessage)")
        #expect(!repo.git.worktrees(repo.path).contains { $0.branch == "desenchufada" })
    }

    @Test("Durante un rebase: la rama sale de head-name, operation es .rebase y el UU se lee")
    func rebaseInProgress() throws {
        let repo = GitRepo()
        repo.write("c.txt", "base\n")
        repo.commit("Base")
        repo.sh("git checkout -q -b feat")
        repo.write("c.txt", "feat\n")
        repo.commit("Feat")
        repo.sh("git checkout -q main")
        repo.write("c.txt", "main\n")
        repo.commit("Main")
        // Worktree con la rama feat, rebaseando sobre main (el .git es un archivo que apunta a la carpeta real).
        let worktree = repo.dir.url.path + "/wt-feat"
        repo.sh("git worktree add -q \(shellQuote(worktree)) feat")
        repo.sh("git rebase main", in: worktree)
        #expect(repo.git.currentBranch(worktree) == "feat")
        let status = try #require(repo.git.status(worktree))
        #expect(status.operation == .rebase)
        #expect(status.branch == "feat")
        let change = try #require(status.changes.first)
        #expect(change.code == "UU" && change.path == "c.txt")
        #expect(repo.git.diff(for: change, staged: false, in: worktree).lines.contains { $0.kind == .conflictMarker })

        // Lo mismo en la carpeta principal.
        repo.sh("git checkout -q -b otra feat~0 && git rebase main")
        #expect(repo.git.currentBranch(repo.path) == "otra")
        #expect(repo.git.status(repo.path)?.operation == .rebase)
        repo.sh("git rebase --abort")
        #expect(repo.git.status(repo.path)?.operation == nil)
    }

    @Test("Repo sin commits: lo explica, y con el primer commit ya se puede crear la rama")
    func noCommits() throws {
        let dir = TempDir()
        let git = GitCLI()
        #expect(git.initRepository(dir.path).ok)
        let config = ProcessCommandRunner().run("/bin/sh", ["-c", "git config user.email t@e.com && git config user.name Test && git config commit.gpgsign false"],
                                                cwd: dir.path)
        #expect(config.ok)
        let p = Project(name: "nuevo", path: dir.path)
        let request = NewBranchRequest(projectId: p.id, name: "feature/x", isNew: true, mode: .worktree)
        guard case .failure(let error) = BranchPlanner.prepare(request, project: p, git: git) else {
            Issue.record("Esperaba un error")
            return
        }
        #expect(error == .noCommits)
        #expect(git.status(dir.path)?.isUnborn == true)
        // Un archivo preparado no entra en el primer commit, que es vacío, y sigue preparado.
        dir.write("preparado.txt", "x\n")
        #expect(git.run(["add", "preparado.txt"], in: dir.path).ok)
        #expect(git.commitAllowEmpty(message: "Primer commit", in: dir.path).ok)
        #expect(git.status(dir.path)?.isUnborn == false)
        #expect(git.run(["ls-tree", "-r", "--name-only", "HEAD"], in: dir.path).output.isEmpty)
        #expect(git.status(dir.path)?.changes.map(\.code) == ["A "])
        #expect((try? BranchPlanner.prepare(request, project: p, git: git).get())?.mode == .worktree)
    }

    @Test("HEAD desacoplado y sin ramas locales no es un repo sin commits: la rama se crea desde HEAD")
    func detachedWithoutLocalBranches() throws {
        let repo = GitRepo()
        repo.sh("git checkout -q --detach && git branch -q -D main")
        #expect(repo.git.localBranches(repo.path).isEmpty)
        let created = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "desde-head", isNew: true, mode: .worktree),
                                                project: project(repo), git: repo.git).get()
        #expect(repo.git.currentBranch(try #require(created.worktreePath)) == "desde-head")
    }

    @Test("git checkout -b dentro de un worktree renombra la rama en Hive sin duplicarla")
    func renameInsideWorktree() throws {
        let repo = GitRepo()
        let created = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "feature-x", isNew: true, base: "main", mode: .worktree),
                                                project: project(repo), git: repo.git).get()
        let path = try #require(created.worktreePath)
        var withSession = created
        withSession.sessions = [Session(name: "Claude", kind: .claude)]
        withSession.color = .green
        let p = project(repo, branches: [Branch(name: "main", mode: .main), withSession])
        repo.sh("git checkout -q -b fix/foo", in: path)
        let result = try #require(WorktreeSync.apply(repo.git.worktrees(repo.path), to: p))
        #expect(result.project.branches.map(\.name) == ["main", "fix/foo"])
        #expect(result.added.isEmpty)
        let renamed = result.project.branches[1]
        #expect(renamed.id == withSession.id && renamed.sessions.count == 1 && renamed.color == .green)
    }

    @Test("WorktreeSync por ruta: no pisa un nombre que ya tiene otra rama de Hive")
    func renameKeepsExistingName() throws {
        let worktree = Branch(name: "viejo", mode: .worktree, worktreePath: "/wt/a")
        let other = Branch(name: "nuevo", mode: .main)
        let p = Project.make(path: "/repo", branches: [Branch(name: "main", mode: .main), worktree, other])
        #expect(WorktreeSync.apply([GitWorktree(path: "/wt/a", branch: "nuevo")], to: p, exists: { _ in true }) == nil)
        let renamed = try #require(WorktreeSync.apply([GitWorktree(path: "/wt/a", branch: "otro")], to: p, exists: { _ in true }))
        #expect(renamed.project.branches.map(\.name) == ["main", "otro", "nuevo"])
        #expect(renamed.project.branches[1].id == worktree.id)
    }

    @Test("Comillas, «->» en el nombre y git mv: el status y los diffs se leen bien")
    func oddFileNames() throws {
        let repo = GitRepo()
        repo.write("viejo.txt", "uno\ndos\n")
        repo.write("otro.txt", "a\nb\nc\n")
        repo.commit("Base")
        repo.sh("git mv viejo.txt 'nuevo nombre.txt' && git mv otro.txt movido.txt")
        repo.write("movido.txt", "a\nB\nc\n")
        repo.sh("git add movido.txt")
        repo.write("a -> b.txt", "x\n")
        repo.write("con\"comilla.txt", "y\n")
        let status = try #require(repo.git.status(repo.path))
        let paths = Set(status.changes.map(\.path))
        #expect(paths == ["nuevo nombre.txt", "movido.txt", "a -> b.txt", "con\"comilla.txt"])

        let pure = try #require(status.changes.first { $0.path == "nuevo nombre.txt" })
        #expect(pure.code.hasPrefix("R") && pure.originalPath == "viejo.txt")
        let pureDiff = repo.git.diff(for: pure, staged: true, in: repo.path)
        #expect(pureDiff.addedCount == 0 && pureDiff.removedCount == 0) // no aparece como archivo nuevo
        #expect(pureDiff.message?.contains("viejo.txt") == true)

        let moved = try #require(status.changes.first { $0.path == "movido.txt" })
        let movedDiff = repo.git.diff(for: moved, staged: true, in: repo.path)
        #expect(movedDiff.addedCount == 1 && movedDiff.removedCount == 1)

        for name in ["a -> b.txt", "con\"comilla.txt"] {
            let change = try #require(status.changes.first { $0.path == name })
            let diff = repo.git.diff(for: change, staged: false, in: repo.path)
            #expect(diff.addedCount == 1 && diff.message == nil, "\(name): \(diff.message ?? "")")
        }
    }

    @Test("Upstream borrado en el remoto se detecta")
    func upstreamGone() throws {
        let repo = GitRepo()
        _ = repo.addRemote()
        repo.sh("git checkout -q -b feat && git push -q -u origin feat 2>/dev/null")
        #expect(repo.git.status(repo.path)?.upstreamGone == false)
        repo.sh("git push -q origin --delete feat 2>/dev/null && git fetch -q --prune")
        let status = try #require(repo.git.status(repo.path))
        #expect(status.upstreamGone && status.upstream == "origin/feat")
        #expect(status.headOid?.count == 40)
    }

    @Test("Publicar, traer y datos del remoto")
    func remoteOperations() throws {
        let repo = GitRepo()
        let remote = repo.addRemote()
        #expect(repo.git.remotes(repo.path) == ["origin"])
        #expect(repo.git.remoteURL(repo.path).map { samePath($0, remote) } == true)
        repo.sh("git checkout -q -b publicar")
        repo.write("p.txt", "p")
        repo.commit("Para publicar")
        let pushed = repo.git.push(branch: "publicar", setUpstream: true, in: repo.path)
        #expect(pushed.ok, "\(pushed.errorMessage)")
        #expect(upstream(repo, "publicar") == "origin/publicar")
        #expect(repo.git.fetch(repo.path).ok)

        // Otro clon empuja un commit; acá se trae con --ff-only.
        let clone = repo.dir.url.path + "/clon"
        repo.sh("git clone -q \(shellQuote(remote)) \(shellQuote(clone))")
        repo.sh("git config user.email t@e.com && git config user.name T && git checkout -q publicar && echo q > q.txt && git add q.txt && git commit -q -m remoto && git push -q 2>/dev/null",
                in: clone)
        let pulled = repo.git.pull(ffOnly: true, in: repo.path)
        #expect(pulled.ok, "\(pulled.errorMessage)")
        #expect(FileManager.default.fileExists(atPath: repo.path + "/q.txt"))

        // Commits de otra rama sin cambiar de rama, y la carpeta principal desde un worktree.
        #expect(repo.git.recentCommits(repo.path, ref: "main", limit: 5).map(\.subject) == ["Primer commit"])
        let worktree = repo.dir.url.path + "/wt"
        repo.sh("git worktree add -q -b wt \(shellQuote(worktree))")
        #expect(repo.git.mainWorktree(worktree).map { samePath($0, repo.path) } == true)
        #expect(GitCLI().remoteURL(TempDir().path) == nil)
    }

    @Test("Crear un worktree hermano copia solo los .env ignorados y reescribe APP_URL")
    func readyForHerd() throws {
        let repo = GitRepo(name: "emplag-v2")
        repo.write(".gitignore", ".env\nauth.json\n")
        repo.write(".env.example", "APP_URL=http://localhost\n")
        repo.write("polyscope.json", #"{"scripts": {"archive": ["herd unsecure", "herd unlink"]}}"#)
        repo.commit("Base")
        repo.write(".env", "APP_NAME=Emplag\nAPP_URL=https://emplag-v2.test\nSESSION_DOMAIN=.emplag-v2.test\n")
        let request = NewBranchRequest(projectId: UUID(), name: "feature/telefonos", isNew: true, base: "main", mode: .worktree,
                                       location: .sibling, copyIgnored: true, envAppURL: "https://emplag-v2-telefonos.test",
                                       setupCommand: "  composer install  ")
        let prepared = try BranchPlanner.prepareDetailed(request, project: project(repo), git: repo.git).get()
        let path = try #require(prepared.branch.worktreePath)
        #expect(path == repo.dir.url.path + "/emplag-v2-telefonos")
        #expect(prepared.copiedFiles == [".env"])
        #expect(prepared.setupCommand == "composer install")
        #expect(prepared.archiveCommand == "herd unsecure && herd unlink")
        let env = try String(contentsOfFile: path + "/.env", encoding: .utf8)
        #expect(env == "APP_NAME=Emplag\nAPP_URL=https://emplag-v2-telefonos.test\nSESSION_DOMAIN=.emplag-v2-telefonos.test\n")
        // El .env.example llega por git, sin tocar.
        #expect((try String(contentsOfFile: path + "/.env.example", encoding: .utf8)) == "APP_URL=http://localhost\n")
        // El .env del principal sigue igual.
        #expect((try String(contentsOfFile: repo.path + "/.env", encoding: .utf8)).contains("https://emplag-v2.test"))

        // Sin pedirlo, no copia nada.
        let plain = try BranchPlanner.prepareDetailed(NewBranchRequest(projectId: UUID(), name: "sin-copia", isNew: true, base: "main", mode: .worktree),
                                                      project: project(repo), git: repo.git).get()
        #expect(plain.copiedFiles.isEmpty && plain.setupCommand == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(plain.branch.worktreePath) + "/.env"))
    }

    @Test("Ruta de worktree hermana: sin feature/, fix/ ni chore/ y sin pisar carpetas")
    func siblingPath() {
        #expect(GitParsing.worktreePath(for: "feature/checkout", projectPath: "/Herd/app", style: .sibling, exists: { _ in false }) == "/Herd/app-checkout")
        #expect(GitParsing.worktreePath(for: "fix/login", projectPath: "/Herd/app", style: .sibling, exists: { _ in false }) == "/Herd/app-login")
        #expect(GitParsing.worktreePath(for: "chore/deps/x", projectPath: "/Herd/app", style: .sibling, exists: { _ in false }) == "/Herd/app-deps-x")
        #expect(GitParsing.worktreePath(for: "SEGURIDAD", projectPath: "/Herd/app", style: .sibling, exists: { _ in false }) == "/Herd/app-SEGURIDAD")
        #expect(GitParsing.worktreePath(for: "feature/", projectPath: "/Herd/app", style: .sibling, exists: { _ in false }) == "/Herd/app-feature-")
        let taken: Set = ["/Herd/app-x", "/Herd/app-x-2"]
        #expect(GitParsing.worktreePath(for: "feature/x", projectPath: "/Herd/app", style: .sibling, exists: { taken.contains($0) }) == "/Herd/app-x-3")
        #expect(GitParsing.worktreePath(for: "feature/x", projectPath: "/Herd/app", style: .nested, exists: { _ in false }) == "/Herd/app.worktrees/feature-x")
    }
}
