import Foundation
import Testing
@testable import HiveCore

@Suite("Lectura de git status")
struct GitStatusParsingTests {
    @Test("Rama, upstream y commits adelante/atrás")
    func header() {
        let s = GitParsing.status("## main...origin/main [ahead 2, behind 3]\n")
        #expect(s.branch == "main")
        #expect(s.upstream == "origin/main")
        #expect(s.ahead == 2 && s.behind == 3)
        #expect(s.changes.isEmpty)
        #expect(!s.isClean)
    }

    @Test("Variantes del encabezado", arguments: [
        ("## main", "main", nil, 0, 0),
        ("## main...origin/main", "main", "origin/main", 0, 0),
        ("## feature/x...origin/feature/x [behind 1]", "feature/x", "origin/feature/x", 0, 1),
        ("## No commits yet on trunk", "trunk", nil, 0, 0),
        ("## HEAD (no branch)", nil, nil, 0, 0),
        ("## main...origin/main [gone]", "main", "origin/main", 0, 0),
    ] as [(String, String?, String?, Int, Int)])
    func headers(line: String, branch: String?, upstream: String?, ahead: Int, behind: Int) {
        let s = GitParsing.status(line)
        #expect(s.branch == branch)
        #expect(s.upstream == upstream)
        #expect(s.ahead == ahead && s.behind == behind)
    }

    @Test("Archivos: renombres, comillas y códigos")
    func files() {
        let s = GitParsing.status("""
        ## main
         M src/app.py
        A  nuevo.ts
        R  viejo.txt -> carpeta/nuevo.txt
        ?? "con espacios.md"
        UU conflicto.php
        """)
        #expect(s.changes.map(\.code) == [" M", "A ", "R ", "??", "UU"])
        #expect(s.changes.map(\.path) == ["src/app.py", "nuevo.ts", "carpeta/nuevo.txt", "con espacios.md", "conflicto.php"])
        #expect(GitParsing.status("## main\n").isClean)
    }
}

@Suite("Cambios de git")
struct GitChangeTests {
    @Test("Preparado, sin preparar y letra de cada estado", arguments: [
        // código, preparado, sin preparar, letra preparado, letra sin preparar
        (" M", false, true, " ", "M"),
        ("M ", true, false, "M", " "),
        ("MM", true, true, "M", "M"),
        ("A ", true, false, "A", " "),
        ("AM", true, true, "A", "M"),
        (" D", false, true, " ", "D"),
        ("D ", true, false, "D", " "),
        ("R ", true, false, "R", " "),
        ("??", false, true, "U", "U"),
        ("UU", false, true, "!", "!"),
        ("AA", false, true, "!", "!"),
        ("DD", false, true, "!", "!"),
    ])
    func badges(code: String, staged: Bool, unstaged: Bool, stagedBadge: String, unstagedBadge: String) {
        let change = GitChange(code: code, path: "x")
        #expect(change.isStaged == staged)
        #expect(change.isUnstaged == unstaged)
        #expect(change.badge(staged: true) == stagedBadge)
        #expect(change.badge(staged: false) == unstagedBadge)
    }

    @Test("Nombre y carpeta del archivo")
    func names() {
        let file = GitChange(code: " M", path: "app/Http/Controller.php")
        #expect(file.fileName == "Controller.php")
        #expect(file.folder == "app/Http")
        let root = GitChange(code: " M", path: "README.md")
        #expect(root.folder.isEmpty)
        let dir = GitChange(code: "??", path: "nueva/carpeta/")
        #expect(dir.fileName == "carpeta")
        #expect(dir.folder == "nueva")
        #expect(dir.isUntracked)
    }
}

@Suite("Lectura de worktrees, commits y diffs")
struct GitOtherParsingTests {
    @Test("Worktrees en formato porcelain")
    func worktrees() {
        let list = GitParsing.worktrees("""
        worktree /repo
        HEAD 1111111
        branch refs/heads/main

        worktree /repo.worktrees/feature-login
        HEAD 2222222
        branch refs/heads/feature/login

        worktree /tmp/suelto
        HEAD 3333333
        detached

        """)
        #expect(list == [
            GitWorktree(path: "/repo", branch: "main"),
            GitWorktree(path: "/repo.worktrees/feature-login", branch: "feature/login"),
            GitWorktree(path: "/tmp/suelto", branch: nil),
        ])
        #expect(GitParsing.worktrees("").isEmpty)
    }

    @Test("Commits con separadores de unidad")
    func commits() {
        let text = "abc1234\u{1f}Arreglo el login\u{1f}Ana\u{1f}1790000000\ndef5678\u{1f}Con\u{1f}separador en el texto? no\u{1f}Bo\u{1f}x\n"
        let commits = GitParsing.commits(text)
        #expect(commits.count == 1) // la segunda línea está mal formada
        #expect(commits[0] == GitCommit(hash: "abc1234", subject: "Arreglo el login", author: "Ana", date: .reference))
    }

    @Test("Diff con números de línea, varias partes y notas")
    func diff() {
        let d = GitParsing.diff("""
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,4 @@ encabezado
         uno
        -dos
        +DOS
        +dos y medio
         tres
        @@ -10,2 +11,2 @@
         diez
        -once
        +ONCE
        \\ No newline at end of file

        """)
        #expect(d.lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context, .hunk, .context, .removed, .added, .note])
        #expect(d.lines[1].oldNumber == 1 && d.lines[1].newNumber == 1)
        #expect(d.lines[2].oldNumber == 2 && d.lines[2].newNumber == nil)
        #expect(d.lines[3].newNumber == 2 && d.lines[4].newNumber == 3)
        #expect(d.lines[5].oldNumber == 3 && d.lines[5].newNumber == 4)
        #expect(d.lines[7].oldNumber == 10 && d.lines[7].newNumber == 11)
        #expect(d.lines[10].text == "No newline at end of file")
        #expect(d.addedCount == 3 && d.removedCount == 2)
        #expect(d.lines.map(\.id) == Array(0..<11))
        #expect(!d.isBinary && !d.truncated)
    }

    @Test("Archivo binario")
    func binary() {
        let d = GitParsing.diff("diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n")
        #expect(d.isBinary)
        #expect(d.lines.isEmpty)
    }

    @Test("Corta los diffs muy largos")
    func truncated() {
        let body = (0..<50).map { "+línea \($0)" }.joined(separator: "\n")
        let d = GitParsing.diff("@@ -0,0 +1,50 @@\n" + body, maxLines: 10)
        #expect(d.lines.count == 10)
        #expect(d.truncated)
    }

    @Test("Nombre de carpeta para una rama", arguments: [
        ("feature/login", "feature-login"), ("fix bug", "fix-bug"), ("v1.2_rc", "v1.2_rc"), ("ñ/á", "ñ-á"),
    ])
    func slug(name: String, expected: String) {
        #expect(GitParsing.slug(name) == expected)
    }

    @Test("Ruta del worktree junto al proyecto, sin pisar carpetas existentes")
    func worktreePath() {
        #expect(GitParsing.worktreePath(for: "feature/x", projectPath: "/code/app", exists: { _ in false })
                == "/code/app.worktrees/feature-x")
        let taken: Set = ["/code/app.worktrees/feature-x", "/code/app.worktrees/feature-x-2"]
        #expect(GitParsing.worktreePath(for: "feature/x", projectPath: "/code/app", exists: { taken.contains($0) })
                == "/code/app.worktrees/feature-x-3")
    }
}

@Suite("Cliente de git (repos reales)")
struct GitCLITests {
    @Test("Raíz del repo, también desde una subcarpeta; nil fuera de un repo")
    func topLevel() throws {
        let repo = GitRepo()
        repo.write("src/a.txt", "a")
        #expect(repo.git.topLevel(repo.path) == repo.path)
        #expect(repo.git.topLevel(repo.path + "/src") == repo.path)
        let outside = TempDir()
        #expect(repo.git.topLevel(outside.path) == nil)
        #expect(repo.git.topLevel("/no/existe") == nil)
    }

    @Test("Rama actual, y nil con HEAD desacoplado")
    func currentBranch() {
        let repo = GitRepo(branch: "trunk")
        #expect(repo.git.currentBranch(repo.path) == "trunk")
        repo.sh("git checkout -q --detach")
        #expect(repo.git.currentBranch(repo.path) == nil)
    }

    @Test("Ramas locales y remotas")
    func branches() {
        let repo = GitRepo()
        repo.sh("git branch feature/a && git branch fix")
        #expect(Set(repo.git.localBranches(repo.path)) == ["main", "feature/a", "fix"])
        #expect(repo.git.remoteBranches(repo.path).isEmpty)
        _ = repo.addRemote()
        repo.sh("git push -q origin fix")
        #expect(Set(repo.git.remoteBranches(repo.path)) == ["origin/main", "origin/fix"])
    }

    @Test("Estado con cambios preparados, sin preparar, nuevos y commits sin pushear")
    func status() throws {
        let repo = GitRepo()
        _ = repo.addRemote()
        repo.write("README.md", "# Cambiado\n")
        repo.write("nuevo.txt", "hola")
        repo.write("preparado.txt", "x")
        repo.sh("git add preparado.txt")
        let status = try #require(repo.git.status(repo.path))
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(Set(status.changes.map { "\($0.code)|\($0.path)" }) == [" M|README.md", "??|nuevo.txt", "A |preparado.txt"])
        repo.commit("Todo")
        let after = try #require(repo.git.status(repo.path))
        #expect(after.ahead == 1)
        #expect(after.changes.isEmpty)
        #expect(repo.git.status("/no/existe") == nil)
    }

    @Test("Worktrees: crear con rama nueva, con rama existente, listar y borrar")
    func worktrees() throws {
        let repo = GitRepo()
        let base = repo.dir.url.path
        let nuevo = base + "/wt-nuevo"
        #expect(repo.git.addWorktree(at: nuevo, branch: "nuevo", newBranch: true, base: "main", in: repo.path).ok)
        repo.sh("git branch existente")
        let existente = base + "/wt-existente"
        #expect(repo.git.addWorktree(at: existente, branch: "existente", newBranch: false, base: nil, in: repo.path).ok)
        let list = repo.git.worktrees(repo.path)
        // La carpeta principal va primero; el resto en el orden que elige git.
        #expect(list.first?.branch == "main")
        #expect(Set(list.compactMap(\.branch)) == ["main", "nuevo", "existente"])
        #expect(list.contains { $0.branch == "nuevo" && $0.path == nuevo })

        // Con cambios sin commitear hay que forzar el borrado.
        try "sucio".write(toFile: nuevo + "/sucio.txt", atomically: true, encoding: .utf8)
        #expect(!repo.git.removeWorktree(nuevo, force: false, in: repo.path).ok)
        #expect(repo.git.removeWorktree(nuevo, force: true, in: repo.path).ok)
        #expect(!FileManager.default.fileExists(atPath: nuevo))
        // Una rama que ya está en otro worktree no se puede volver a usar.
        #expect(!repo.git.addWorktree(at: base + "/otra", branch: "existente", newBranch: false, base: nil, in: repo.path).ok)
    }

    @Test("Crear rama, checkout y nombres válidos")
    func branchOps() {
        let repo = GitRepo()
        #expect(repo.git.createBranch("feature/x", from: "HEAD", in: repo.path).ok)
        #expect(!repo.git.createBranch("feature/x", from: "HEAD", in: repo.path).ok) // ya existe
        #expect(repo.git.checkout("feature/x", in: repo.path).ok)
        #expect(repo.git.currentBranch(repo.path) == "feature/x")
        #expect(!repo.git.checkout("no-existe", in: repo.path).ok)
        #expect(repo.git.isValidBranchName("feature/ok", in: repo.path))
        #expect(!repo.git.isValidBranchName("mal..nombre", in: repo.path))
        #expect(!repo.git.isValidBranchName("con espacio", in: repo.path))
    }

    @Test("Inicializar un repo")
    func initRepo() {
        let dir = TempDir()
        let git = GitCLI()
        #expect(git.topLevel(dir.path) == nil)
        #expect(git.initRepository(dir.path).ok)
        #expect(git.topLevel(dir.path) != nil)
    }

    @Test("Últimos commits")
    func commits() {
        let repo = GitRepo()
        repo.write("a.txt", "a")
        repo.commit("Segundo commit")
        let commits = repo.git.recentCommits(repo.path, limit: 5)
        #expect(commits.map(\.subject) == ["Segundo commit", "Primer commit"])
        #expect(commits.allSatisfy { $0.author == "Test" && $0.hash.count >= 7 })
        #expect(repo.git.recentCommits(repo.path, limit: 1).count == 1)
    }

    @Test("Diffs de cambios sin preparar, preparados, nuevos, borrados y carpetas")
    func diffs() {
        let repo = GitRepo()
        repo.write("src/app.txt", "uno\ndos\ntres\n")
        repo.write("borrar.txt", "chau\n")
        repo.commit("Base")
        repo.write("src/app.txt", "uno\nDOS\ntres\ncuatro\n")
        repo.write("preparado.txt", "p\n")
        repo.sh("git add preparado.txt && rm borrar.txt")
        repo.write("nuevo.txt", "n1\nn2\n")

        let modified = repo.git.diff(for: GitChange(code: " M", path: "src/app.txt"), staged: false, in: repo.path)
        #expect(modified.addedCount == 2 && modified.removedCount == 1)
        let staged = repo.git.diff(for: GitChange(code: "A ", path: "preparado.txt"), staged: true, in: repo.path)
        #expect(staged.addedCount == 1)
        let untracked = repo.git.diff(for: GitChange(code: "??", path: "nuevo.txt"), staged: false, in: repo.path)
        #expect(untracked.addedCount == 2 && untracked.message == nil)
        let deleted = repo.git.diff(for: GitChange(code: " D", path: "borrar.txt"), staged: false, in: repo.path)
        #expect(deleted.removedCount == 1)
        let folder = repo.git.diff(for: GitChange(code: "??", path: "carpeta/"), staged: false, in: repo.path)
        #expect(folder.message != nil && folder.lines.isEmpty)
    }
}

@Suite("Preparar ramas (repos reales)")
struct BranchPlannerTests {
    func project(_ repo: GitRepo, branches: [Branch] = [Branch(name: "main", mode: .main)]) -> Project {
        Project(name: "repo", path: repo.path, branches: branches)
    }

    @Test("Rama nueva en worktree: lo crea junto al repo")
    func newWorktree() throws {
        let repo = GitRepo()
        let request = NewBranchRequest(projectId: UUID(), name: " feature/login ", isNew: true, base: "main", mode: .worktree)
        let branch = try BranchPlanner.prepare(request, project: project(repo), git: repo.git).get()
        #expect(branch.name == "feature/login")
        #expect(branch.mode == .worktree)
        let path = try #require(branch.worktreePath)
        #expect(path.hasSuffix("repo.worktrees/feature-login"))
        #expect(FileManager.default.fileExists(atPath: path + "/README.md"))
        #expect(repo.git.currentBranch(path) == "feature/login")
    }

    @Test("Rama nueva en la carpeta principal: la crea sin hacer checkout")
    func newMain() throws {
        let repo = GitRepo()
        let branch = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "fix", isNew: true, mode: .main),
                                               project: project(repo), git: repo.git).get()
        #expect(branch.mode == .main && branch.worktreePath == nil)
        #expect(repo.git.localBranches(repo.path).contains("fix"))
        #expect(repo.git.currentBranch(repo.path) == "main")
    }

    @Test("Rama existente: adopta su worktree si ya tiene uno")
    func adoptsWorktree() throws {
        let repo = GitRepo()
        let path = repo.dir.url.path + "/externo"
        repo.sh("git worktree add -q -b externa \(shellQuote(path))")
        let branch = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "externa", isNew: false, mode: .main),
                                               project: project(repo), git: repo.git).get()
        #expect(branch.mode == .worktree)
        #expect(samePath(try #require(branch.worktreePath), path))
    }

    @Test("Rama existente: la que tiene checkout en la carpeta principal queda en modo principal")
    func adoptsMainFolder() throws {
        let repo = GitRepo()
        let branch = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "main", isNew: false, mode: .worktree),
                                               project: project(repo, branches: []), git: repo.git).get()
        #expect(branch.mode == .main)
    }

    @Test("Rama existente sin worktree: crea uno o la deja para checkout")
    func existingWithoutWorktree() throws {
        let repo = GitRepo()
        repo.sh("git branch suelta && git branch otra")
        let worktree = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "suelta", isNew: false, mode: .worktree),
                                                 project: project(repo), git: repo.git).get()
        #expect(worktree.mode == .worktree)
        #expect(repo.git.currentBranch(try #require(worktree.worktreePath)) == "suelta")
        let main = try BranchPlanner.prepare(NewBranchRequest(projectId: UUID(), name: "otra", isNew: false, mode: .main),
                                             project: project(repo), git: repo.git).get()
        #expect(main.mode == .main)
    }

    @Test("Errores: vacío, ya en Hive, inválido, ya existe y fallo de git")
    func errors() {
        let repo = GitRepo()
        repo.sh("git branch existe")
        let p = project(repo)
        func prepare(_ name: String, isNew: Bool = true, base: String = "") -> BranchError? {
            if case .failure(let error) = BranchPlanner.prepare(NewBranchRequest(projectId: p.id, name: name, isNew: isNew, base: base, mode: .worktree),
                                                                project: p, git: repo.git) { return error }
            return nil
        }
        #expect(prepare("  ") == .emptyName)
        #expect(prepare("main") == .alreadyInHive("main"))
        #expect(prepare("mal..nombre") == .invalidName("mal..nombre"))
        #expect(prepare("existe") == .alreadyExists("existe"))
        guard case .git(let message)? = prepare("nueva", base: "base-inexistente") else {
            Issue.record("Esperaba un error de git")
            return
        }
        #expect(!message.isEmpty)
        #expect(BranchError.emptyName.errorDescription == "Poné el nombre de la rama.")
        #expect(BranchError.git("detalle").errorDescription == "detalle")
    }
}
