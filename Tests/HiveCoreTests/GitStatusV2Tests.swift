import Foundation
import Testing
@testable import HiveCore

@Suite("git status --porcelain=v2 -z")
struct GitStatusV2Tests {
    /// Une los registros como los separa git con -z.
    func z(_ records: String...) -> String { records.map { $0 + "\0" }.joined() }

    @Test("Encabezado: HEAD, rama, upstream y commits adelante/atrás")
    func header() {
        let s = GitParsing.statusV2(z("# branch.oid 9f4cfa83ac229cc1d7145eedf2b5979367211adc", "# branch.head feature/x",
                                      "# branch.upstream origin/feature/x", "# branch.ab +2 -3"))
        #expect(s.headOid == "9f4cfa83ac229cc1d7145eedf2b5979367211adc")
        #expect(s.branch == "feature/x")
        #expect(s.upstream == "origin/feature/x")
        #expect(s.ahead == 2 && s.behind == 3)
        #expect(!s.upstreamGone && !s.isUnborn)
        #expect(s.changes.isEmpty)
    }

    @Test("Upstream borrado: hay branch.upstream pero no branch.ab")
    func gone() {
        let s = GitParsing.statusV2(z("# branch.oid abc", "# branch.head feat", "# branch.upstream origin/feat"))
        #expect(s.upstream == "origin/feat")
        #expect(s.upstreamGone)
        #expect(s.ahead == 0 && s.behind == 0)
        // Sin upstream no está «borrado».
        #expect(!GitParsing.statusV2(z("# branch.oid abc", "# branch.head feat")).upstreamGone)
    }

    @Test("Repo sin commits y HEAD desacoplado")
    func specialHeads() {
        let unborn = GitParsing.statusV2(z("# branch.oid (initial)", "# branch.head main"))
        #expect(unborn.isUnborn && unborn.headOid == nil && unborn.branch == "main")
        let detached = GitParsing.statusV2(z("# branch.oid abc", "# branch.head (detached)"))
        #expect(detached.branch == nil && detached.headOid == "abc")
    }

    @Test("Rutas crudas: comillas, espacios, «->» en el nombre y carpetas nuevas")
    func rawPaths() {
        let s = GitParsing.statusV2(z(
            "# branch.oid abc", "# branch.head main",
            "1 .M N... 100644 100644 100644 e69de29 e69de29 src/con espacios.txt",
            "1 A. N... 000000 100644 100644 0000000 e69de29 nuevo.ts",
            "1 MM N... 100644 100644 100644 e69de29 e69de29 ñandú/año.md",
            "? a -> b.txt",
            "? with\"quote.txt",
            "? carpeta/"))
        #expect(s.changes.map(\.code) == [" M", "A ", "MM", "??", "??", "??"])
        #expect(s.changes.map(\.path) == ["src/con espacios.txt", "nuevo.ts", "ñandú/año.md", "a -> b.txt", "with\"quote.txt", "carpeta/"])
        #expect(s.changes.allSatisfy { $0.originalPath == nil })
        #expect(s.changes[3].isUntracked && s.changes[5].path.hasSuffix("/"))
    }

    @Test("Renombre (R100) con la ruta original en el registro siguiente")
    func rename() throws {
        let s = GitParsing.statusV2(z(
            "# branch.oid abc", "# branch.head main",
            "2 R. N... 100644 100644 100644 e438487 e438487 R100 nuevo nombre.txt", "viejo nombre.txt",
            "2 RM N... 100644 100644 100644 e438487 e438487 R87 b/c.txt", "a.txt",
            "1 .D N... 100644 100644 000000 e69de29 e69de29 borrado.txt"))
        #expect(s.changes.count == 3)
        let renamed = s.changes[0]
        #expect(renamed.code == "R " && renamed.path == "nuevo nombre.txt" && renamed.originalPath == "viejo nombre.txt")
        #expect(renamed.isStaged && !renamed.isUnstaged)
        #expect(renamed.badge(staged: true) == "R")
        #expect(s.changes[1].code == "RM" && s.changes[1].originalPath == "a.txt" && s.changes[1].isUnstaged)
        #expect(s.changes[2].code == " D" && s.changes[2].path == "borrado.txt")
    }

    @Test("Conflictos (registros u)")
    func unmerged() {
        let s = GitParsing.statusV2(z(
            "# branch.oid abc", "# branch.head main",
            "u UU N... 100644 100644 100644 100644 df967b9 b19a1e9 950b81b c.txt",
            "u AA N... 000000 100644 100644 100644 0000000 b19a1e9 950b81b nuevo en los dos.txt",
            "u DU N... 100644 000000 100644 000000 df967b9 0000000 950b81b borrado por mí.txt"))
        #expect(s.changes.map(\.code) == ["UU", "AA", "DU"])
        #expect(s.changes.map(\.path) == ["c.txt", "nuevo en los dos.txt", "borrado por mí.txt"])
        #expect(s.changes.allSatisfy { $0.isConflict })
    }

    @Test("Ignora registros desconocidos o cortados sin romperse")
    func garbage() {
        let s = GitParsing.statusV2(z("# branch.head main", "1 .M corto", "! ignorado.log", "x raro", "?"))
        #expect(s.branch == "main")
        #expect(s.changes.isEmpty)
        #expect(GitParsing.statusV2("").changes.isEmpty)
    }

    @Test("El parser de v1 marca el upstream borrado y el repo sin commits")
    func v1Flags() {
        #expect(GitParsing.status("## main...origin/main [gone]").upstreamGone)
        #expect(!GitParsing.status("## main...origin/main [ahead 1]").upstreamGone)
        #expect(GitParsing.status("## No commits yet on trunk").isUnborn)
    }

    @Test("Operación en curso según los archivos de la carpeta de git")
    func operations() {
        func detect(_ files: Set<String>) -> GitOperation? {
            GitParsing.operation(gitDir: "/r/.git", exists: { files.contains($0) })
        }
        #expect(detect([]) == nil)
        #expect(detect(["/r/.git/rebase-merge"]) == .rebase)
        #expect(detect(["/r/.git/rebase-apply"]) == .rebase)
        #expect(detect(["/r/.git/rebase-apply", "/r/.git/rebase-apply/applying"]) == nil) // git am
        #expect(detect(["/r/.git/MERGE_HEAD"]) == .merge)
        #expect(detect(["/r/.git/CHERRY_PICK_HEAD"]) == .cherryPick)
        #expect(detect(["/r/.git/REVERT_HEAD"]) == .revert)
        #expect(detect(["/r/.git/BISECT_LOG"]) == .bisect)
        #expect(GitOperation.rebase.label == "Rebase en curso")
        #expect(GitOperation.rebase.swapsOursAndTheirs && !GitOperation.merge.swapsOursAndTheirs)
    }

    @Test("Archivo .git de un worktree y head-name de un rebase")
    func pointers() {
        #expect(GitParsing.gitDirPointer("gitdir: /repo/.git/worktrees/x\n", relativeTo: "/wt/x") == "/repo/.git/worktrees/x")
        #expect(GitParsing.gitDirPointer("gitdir: ../repo/.git/worktrees/x", relativeTo: "/code/x") == "/code/repo/.git/worktrees/x")
        #expect(GitParsing.gitDirPointer("otra cosa", relativeTo: "/x") == nil)
        #expect(GitParsing.rebaseHeadName("refs/heads/feature/x\n") == "feature/x")
        #expect(GitParsing.rebaseHeadName("detached HEAD") == nil)
    }

    @Test("Worktrees: prunable y locked")
    func worktreeFlags() {
        let list = GitParsing.worktrees("""
        worktree /repo
        HEAD 1111111
        branch refs/heads/main

        worktree /wt-l
        HEAD 1111111
        branch refs/heads/l
        locked "porque s\\303\\255"

        worktree /wt-x
        HEAD 1111111
        branch refs/heads/x
        prunable gitdir file points to non-existent location

        worktree /wt-y
        HEAD 1111111
        branch refs/heads/y
        locked

        """)
        #expect(list.map(\.isLocked) == [false, true, false, true])
        #expect(list.map(\.isPrunable) == [false, false, true, false])
        #expect(list[2] == GitWorktree(path: "/wt-x", branch: "x", isPrunable: true))
    }
}
