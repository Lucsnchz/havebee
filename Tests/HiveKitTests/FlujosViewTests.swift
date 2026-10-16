import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Un repo con un merge a medias: «app/Order.php» en conflicto (los dos lados lo cambiaron).
@MainActor
private final class FlujosConflictRepo {
    let world = TestWorld()
    let repo = GitRepo(name: "bevo")
    let store: AppStore
    let target: DiffTarget

    init() async throws {
        repo.write("app/Order.php", "<?php\n$total = 0;\n")
        repo.commit("Base")
        repo.sh("git checkout -q -b feat")
        repo.write("app/Order.php", "<?php\n$total = $subtotal;\n")
        repo.commit("Ellos")
        repo.sh("git checkout -q main")
        repo.write("app/Order.php", "<?php\n$total = $subtotal + $envio;\n")
        repo.commit("Nosotros")
        repo.sh("git merge feat")
        store = world.makeStore()
        await store.addProject(at: repo.path)
        await store.refreshGitNow()
        let project = try #require(store.repoProjects.first)
        let status = try #require(store.gitStatus(for: project.branches[0], in: project))
        let conflict = try #require(status.changes.first { $0.isConflict })
        target = DiffTarget.make(directory: repo.path, status: status, change: conflict, staged: false)
    }
}

@MainActor
@Suite("Vistas de los flujos peligrosos", .serialized)
struct FlujosViewTests {
    func check(_ view: some View, size: CGSize, name: String) async {
        let defaults = SnapshotDefaults()
        let reps = await Snapshot.render(view, size: size, name: name, defaults: defaults.defaults, settle: 0.8)
        #expect(reps.count == 2, "No se pudo dibujar \(name)")
        for rep in reps { #expect(Snapshot.distinctColors(rep) > 3, "\(name) parece vacía") }
    }

    @Test("«Usar la de ellos» pide confirmar en la barra del conflicto, con el archivo y qué se pierde")
    func conflictConfirmation() async throws {
        let f = try await FlujosConflictRepo()
        await check(DiffSheet(target: f.target, pendingChoice: .theirs).environment(f.store),
                    size: CGSize(width: 1000, height: 520), name: "flujos-01-conflicto-usar-la-de-ellos")
        // «Marcar resuelto» con los marcadores todavía en el archivo.
        await check(DiffSheet(target: f.target, pendingChoice: .markResolved).environment(f.store),
                    size: CGSize(width: 900, height: 520), name: "flujos-02-conflicto-marcadores")
        // El archivo no se tocó: sigue en conflicto, con sus marcadores.
        let text = try String(contentsOfFile: f.repo.path + "/app/Order.php", encoding: .utf8)
        #expect(text.contains("<<<<<<<"))
    }

    @Test("«Marcar resuelto» vuelve a leer el archivo: si lo arreglaste en el editor no pregunta; con marcadores, sí")
    func markResolvedRereadsTheFile() async throws {
        let f = try await FlujosConflictRepo()
        let file = f.target.files[f.target.selected]
        let withMarkers = await DiffSheet.markResolvedCheck(file, in: f.repo.path, git: f.store.git)
        #expect(ConflictPrompt.hasMarkers(withMarkers.diff))
        #expect(withMarkers.prompt?.confirmTitle == "Marcar igual")
        // Con la hoja abierta (y su diff de antes), lo arreglaste a mano en el editor.
        f.repo.write("app/Order.php", "<?php\n$total = $subtotal + $envio + 1;\n")
        let fixed = await DiffSheet.markResolvedCheck(file, in: f.repo.path, git: f.store.git)
        #expect(!ConflictPrompt.hasMarkers(fixed.diff))
        #expect(fixed.prompt == nil)
    }

    @Test("Publicando: junto al spinner hay una X para cancelar (un pre-push puede tardar minutos)")
    func remoteBusyCanCancel() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "bevo")
        // Remoto con forma de GitLab: el menú solo lee la URL, no se conecta.
        repo.sh("git remote add origin git@gitlab.com:dizeg/bevo.git")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        await check(RemoteActionsMenu(project: project, branch: project.branches[0], busy: "Publicando…").environment(store).padding(),
                    size: CGSize(width: 220, height: 60), name: "flujos-03-remoto-publicando")
    }
}
