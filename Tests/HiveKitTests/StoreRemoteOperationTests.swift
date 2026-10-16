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
