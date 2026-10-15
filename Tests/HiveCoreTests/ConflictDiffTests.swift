import Foundation
import Testing
@testable import HiveCore

@Suite("Diffs de archivos en conflicto")
struct ConflictDiffTests {
    @Test("Diff combinado: prefijo de dos columnas, marcadores y números de la versión final")
    func combined() {
        let d = GitParsing.diff("""
        diff --cc c.txt
        index b19a1e9,950b81b..0000000
        --- a/c.txt
        +++ b/c.txt
        @@@ -1,1 -1,1 +1,5 @@@
        ++<<<<<<< HEAD
         +ours
        ++=======
        + theirs
        ++>>>>>>> feat

        """)
        #expect(d.isCombined)
        #expect(d.lines.map(\.kind) == [.hunk, .conflictMarker, .added, .conflictMarker, .added, .conflictMarker])
        #expect(d.lines.map(\.text) == ["@@@ -1,1 -1,1 +1,5 @@@", "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feat"])
        #expect(d.lines.dropFirst().map(\.newNumber) == [1, 2, 3, 4, 5])
        #expect(d.addedCount == 2 && d.removedCount == 0)
        #expect(d.raw.hasPrefix("diff --cc c.txt"))
    }

    @Test("Diff combinado con contexto, líneas quitadas y estilo diff3")
    func combinedWithContext() {
        let d = GitParsing.diff("""
        diff --cc app.php
        index 1,2..0
        @@@ -10,4 -10,4 +10,8 @@@ class App
          antes
        ++<<<<<<< HEAD
         +$a = 1;
        ++||||||| base
        ++$a = 0;
        ++=======
        + $a = 2;
        ++>>>>>>> otra
        - $viejo = true;
          después
        """)
        #expect(d.lines.map(\.kind) == [.hunk, .context, .conflictMarker, .added, .conflictMarker, .added, .conflictMarker,
                                        .added, .conflictMarker, .removed, .context])
        #expect(d.lines[1].oldNumber == 10 && d.lines[1].newNumber == 10)
        #expect(d.lines[2].newNumber == 11)
        #expect(d.lines[9].text == "$viejo = true;" && d.lines[9].oldNumber == 12)
        #expect(d.lines[10].newNumber == 18)
    }

    @Test("Un diff común no se confunde con uno combinado y vuelve a una columna")
    func normalAfterCombined() {
        let d = GitParsing.diff("""
        diff --cc a.txt
        @@@ -1,1 -1,1 +1,1 @@@
        ++x
        diff --git a/b.txt b/b.txt
        @@ -1 +1 @@
        -viejo
        +nuevo
        """)
        #expect(d.lines.map(\.kind) == [.hunk, .added, .hunk, .removed, .added])
        #expect(d.lines[3].text == "viejo" && d.lines[4].text == "nuevo")
    }

    @Test("Marcadores de conflicto")
    func markers() {
        #expect(GitParsing.isConflictMarker("<<<<<<< HEAD"))
        #expect(GitParsing.isConflictMarker("======="))
        #expect(GitParsing.isConflictMarker(">>>>>>> feat"))
        #expect(GitParsing.isConflictMarker("||||||| base"))
        #expect(!GitParsing.isConflictMarker("========== título"))
        #expect(!GitParsing.isConflictMarker("<<<< menos"))
    }

    @Test("Repo real: el diff de un archivo UU se lee bien y se resuelve con la mía, la de ellos o a mano")
    func realConflict() throws {
        let repo = GitRepo()
        repo.write("c.txt", "base\n")
        repo.write("d.txt", "base\n")
        repo.write("e.txt", "base\n")
        repo.commit("Base")
        repo.sh("git checkout -q -b feat")
        repo.write("c.txt", "theirs\n")
        repo.write("d.txt", "theirs\n")
        repo.write("e.txt", "theirs\n")
        repo.commit("Ellos")
        repo.sh("git checkout -q main")
        repo.write("c.txt", "ours\n")
        repo.write("d.txt", "ours\n")
        repo.write("e.txt", "ours\n")
        repo.commit("Nosotros")
        repo.sh("git merge feat")

        let status = try #require(repo.git.status(repo.path))
        #expect(status.operation == .merge)
        let conflict = try #require(status.changes.first { $0.path == "c.txt" })
        #expect(conflict.code == "UU" && conflict.isConflict)
        let diff = repo.git.diff(for: conflict, staged: false, in: repo.path)
        #expect(diff.isCombined)
        #expect(diff.lines.filter { $0.kind == .conflictMarker }.count == 3)
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "ours" })
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "theirs" })

        #expect(repo.git.resolveConflict(path: "c.txt", using: .ours, in: repo.path).ok)
        #expect((try String(contentsOfFile: repo.path + "/c.txt", encoding: .utf8)) == "ours\n")
        #expect(repo.git.resolveConflict(path: "d.txt", using: .theirs, in: repo.path).ok)
        #expect((try String(contentsOfFile: repo.path + "/d.txt", encoding: .utf8)) == "theirs\n")
        repo.write("e.txt", "a mano\n")
        #expect(repo.git.resolveConflict(path: "e.txt", using: .markResolved, in: repo.path).ok)
        let after = try #require(repo.git.status(repo.path))
        #expect(!after.changes.contains { $0.isConflict })
        #expect(after.operation == .merge) // falta el commit del merge
    }

    @Test("Repo real: si un lado borró el archivo, quedarse con ese lado lo borra")
    func deletedSide() throws {
        let repo = GitRepo()
        repo.write("x.txt", "base\n")
        repo.commit("Base")
        repo.sh("git checkout -q -b feat && git rm -q x.txt && git commit -q -m borro")
        repo.sh("git checkout -q main")
        repo.write("x.txt", "cambio\n")
        repo.commit("Cambio")
        repo.sh("git merge feat")
        let status = try #require(repo.git.status(repo.path))
        let change = try #require(status.changes.first { $0.path == "x.txt" })
        #expect(change.code == "UD")
        let diff = repo.git.diff(for: change, staged: false, in: repo.path)
        #expect(diff.lines.isEmpty == (diff.message != nil))
        #expect(repo.git.resolveConflict(path: "x.txt", using: .theirs, in: repo.path).ok)
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/x.txt"))
        #expect(!(repo.git.status(repo.path)?.changes.contains { $0.isConflict } ?? true))
    }
}
