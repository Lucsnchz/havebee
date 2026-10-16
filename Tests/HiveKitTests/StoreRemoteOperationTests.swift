import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Store: publicar o traer sigue aunque cambies de vista, una por rama y cancelable")
struct StoreRemoteOperationTests {
    @Test("Mientras corre la ve cualquier barra, no se lanza otra encima y la X la corta con un aviso corto")
    func runningIsSharedAndCancellable() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let branch = UUID()
        let dir = TempDir()
        let started = dir.path + "/pre-push-empezo"
        // Como un pre-push que corre la suite de tests: avisa que empezó y tarda.
        let slow: @Sendable (GitClient, String, String) -> CommandResult = { _, _, _ in
            ProcessCommandRunner().run("/bin/sh", ["-c", "touch \(shellQuote(started)); sleep 30"],
                                       cwd: nil, environment: [:], timeout: 60)
        }
        let started1 = store.runRemoteOperation(branchId: branch, directory: dir.path, branchName: "feat",
                                                label: "Publicando…", failureTitle: "No pude publicar la rama",
                                                cancelledNotice: "Cancelaste la publicación de «feat»", slow)
        let task = try #require(started1)
        // Está en el store: la barra que se arma de nuevo al volver a la sesión sigue mostrando el spinner.
        #expect(store.remoteOperations[branch]?.label == "Publicando…")
        // Un segundo «Publicar» (desde la otra barra) no lanza otro push.
        var ranSecond = false
        let second = store.runRemoteOperation(branchId: branch, directory: dir.path, branchName: "feat", label: "Publicando…",
                                              failureTitle: "x", cancelledNotice: "x", slow, then: { ranSecond = true })
        #expect(second == nil)
        // Otra rama sí puede publicar a la vez.
        let quick: @Sendable (GitClient, String, String) -> CommandResult = { _, _, _ in CommandResult(status: 0) }
        let started2 = store.runRemoteOperation(branchId: UUID(), directory: dir.path, branchName: "otra",
                                                label: "Trayendo cambios…", failureTitle: "x", cancelledNotice: "x", quick)
        let other = try #require(started2)
        await other.value

        // Se cancela con el proceso ya corriendo (margen amplio: la máquina puede estar cargada).
        #expect(await waitUntil { FileManager.default.fileExists(atPath: started) })
        let cancelledAt = Date()
        store.cancelRemoteOperation(branchId: branch)
        await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 15)
        #expect(store.remoteOperations[branch] == nil)
        #expect(store.undoAction?.message == "Cancelaste la publicación de «feat»")
        #expect(store.alert == nil)
        #expect(!ranSecond)
    }

    @Test("Quitar la rama y borrar su worktree corta el «Publicar» en curso antes de borrar, sin avisar de una rama que ya no está")
    func removingBranchCancelsPush() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        let marks = TempDir("hive-push")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.createBranch(NewBranchRequest(projectId: project.id, name: "feat", isNew: true, mode: .worktree,
                                                          copyIgnored: false, setupCommand: nil)) == nil)
        let branch = try #require(store.project(project.id)?.branches.first { $0.name == "feat" })
        let dir = try #require(branch.worktreePath)
        let started = marks.path + "/empezo"
        let finished = marks.path + "/termino"
        // Un pre-push que tarda y al terminar escribe en la carpeta del worktree.
        let push: @Sendable (GitClient, String, String) -> CommandResult = { _, dir, _ in
            ProcessCommandRunner().run("/bin/sh", ["-c", "touch \(shellQuote(started)); sleep 30; touch \(shellQuote(finished)); echo x > hook.log"],
                                       cwd: dir, environment: [:], timeout: 60)
        }
        var pushed = false
        let task = try #require(store.runRemoteOperation(branchId: branch.id, directory: dir, branchName: "feat", label: "Publicando…",
                                                         failureTitle: "No pude publicar la rama",
                                                         cancelledNotice: "Cancelaste la publicación de «feat»", push,
                                                         then: { pushed = true }))
        #expect(await waitUntil { FileManager.default.fileExists(atPath: started) })
        // La confirmación dice que se corta.
        store.requestRemoval(.branch(branch.id))
        #expect(store.pendingRemoval?.message.contains("Se cancela «Publicando…».") == true)
        store.pendingRemoval = nil

        let removedAt = Date()
        #expect(await store.performRemove(.branch(branch.id), deleteWorktree: true))
        // Cuando vuelve, el push ya terminó (cortado) y la carpeta no está.
        #expect(Date().timeIntervalSince(removedAt) < 20)
        #expect(store.remoteOperations[branch.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: dir))
        await task.value
        #expect(!FileManager.default.fileExists(atPath: finished))
        // Ni alerta ni «Cancelaste…»: la rama ya no está en Hive.
        #expect(store.alert == nil)
        #expect(store.undoAction == nil)
        #expect(!pushed)
        withExtendedLifetime((world, repo, marks)) {}
    }

    @Test("Quitar un proyecto corta lo que sus ramas hacen con el remoto, y solo queda el «Deshacer»")
    func removingProjectCancelsPull() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        let marks = TempDir("hive-pull")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        let branch = project.branches[0]
        let started = marks.path + "/empezo"
        let slow: @Sendable (GitClient, String, String) -> CommandResult = { _, _, _ in
            ProcessCommandRunner().run("/bin/sh", ["-c", "touch \(shellQuote(started)); sleep 30"], cwd: nil, environment: [:], timeout: 60)
        }
        let task = try #require(store.runRemoteOperation(branchId: branch.id, directory: repo.path, branchName: "main",
                                                         label: "Trayendo cambios…", failureTitle: "No pude traer los cambios",
                                                         cancelledNotice: "Cancelaste la actualización", slow))
        #expect(await waitUntil { FileManager.default.fileExists(atPath: started) })
        store.requestRemoval(.project(project.id))
        #expect(store.pendingRemoval?.message.contains("Se cancela «Trayendo cambios…».") == true)
        store.pendingRemoval = nil

        #expect(await store.performRemove(.project(project.id)))
        #expect(store.remoteOperations.isEmpty)
        let cancelledAt = Date()
        await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 15)
        #expect(store.alert == nil)
        #expect(store.undoAction?.message == "Quitaste «tienda» de Hive")
        withExtendedLifetime((world, repo, marks)) {}
    }

    @Test("Si falla avisa con una alerta; si sale bien, sigue con lo que se pidió (abrir el MR)")
    func failureAndSuccess() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let branch = UUID()
        let rejected: @Sendable (GitClient, String, String) -> CommandResult = { _, _, _ in
            CommandResult(status: 1, stderr: "rechazado por el pre-push")
        }
        let started1 = store.runRemoteOperation(branchId: branch, directory: "/", branchName: "feat", label: "Publicando…",
                                                failureTitle: "No pude publicar la rama", cancelledNotice: "x", rejected)
        let failed = try #require(started1)
        await failed.value
        #expect(store.alert?.title == "No pude publicar la rama")
        #expect(store.alert?.message == "rechazado por el pre-push")
        #expect(store.remoteOperations.isEmpty)
        store.alert = nil

        var opened = false
        let pushed: @Sendable (GitClient, String, String) -> CommandResult = { _, _, _ in CommandResult(status: 0) }
        let started2 = store.runRemoteOperation(branchId: branch, directory: "/", branchName: "feat", label: "Publicando…",
                                                failureTitle: "x", cancelledNotice: "x", pushed, then: { opened = true })
        let ok = try #require(started2)
        await ok.value
        #expect(opened)
        #expect(store.alert == nil)
        #expect(store.remoteOperations.isEmpty)
    }
}
