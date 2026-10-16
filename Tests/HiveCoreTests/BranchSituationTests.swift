import Foundation
import Testing
@testable import HiveCore

@Suite("Situación de una rama")
struct BranchSituationTests {
    @Test("Encabezado, tarjeta y acciones dicen lo mismo", arguments: [
        // modo, activa, sin carpeta, rebase a medias → situación, etiqueta
        (BranchMode.worktree, true, false, false, BranchSituation.worktree, "Worktree"),
        (.worktree, true, true, false, .missing, "Sin carpeta"),
        (.worktree, true, false, true, .worktree, "Worktree"), // el rebase de la carpeta principal no le afecta
        (.main, true, false, false, .main, "Carpeta principal"),
        (.main, true, false, true, .main, "Carpeta principal"),
        (.main, false, false, false, .inactive, "Inactiva"),
        (.main, false, false, true, .blocked, "Inactiva"),
        (.main, false, true, false, .inactive, "Inactiva"), // «sin carpeta» es solo de los worktrees
    ] as [(BranchMode, Bool, Bool, Bool, BranchSituation, String)])
    func situation(mode: BranchMode, active: Bool, missing: Bool, mainBusy: Bool, expected: BranchSituation, label: String) {
        let situation = BranchSituation.of(mode: mode, active: active, missing: missing, mainBusy: mainBusy)
        #expect(situation == expected)
        #expect(situation.label == label)
    }

    @Test("No se ofrece lo que no va a andar", arguments: [
        // situación → sesiones nuevas, rama en disco, carpeta, remoto, naranja
        (BranchSituation.worktree, true, true, true, true, false),
        (.main, true, true, true, true, false),
        (.inactive, true, false, true, true, false), // las sesiones nuevas piden el checkout primero
        (.blocked, false, false, true, true, false), // con un rebase a medias el checkout no anda
        (.missing, false, false, false, false, true), // la única salida es «Quitar de Hive…»
    ] as [(BranchSituation, Bool, Bool, Bool, Bool, Bool)])
    func actions(situation: BranchSituation, sessions: Bool, checkout: Bool, folder: Bool, remote: Bool, warning: Bool) {
        #expect(situation.canStartSessions == sessions)
        #expect(situation.hasCheckout == checkout) // comandos, sitio y cambios
        #expect(situation.hasFolder == folder) // abrir la carpeta en otra app
        #expect(situation.offersRemoteActions == remote) // publicar y el MR
        #expect(situation.isWarning == warning)
    }

    @Test("Sin checkout no se ofrece lanzar comandos, pero los que siguen corriendo se ven para detenerlos")
    func commands() {
        let serve = ProjectCommand(name: "Servidor", command: "php artisan serve")
        let queue = ProjectCommand(name: "Cola", command: "php artisan queue:work")
        let all = [serve, queue]
        let running: (ProjectCommand) -> Bool = { $0.id == queue.id }
        #expect(BranchSituation.worktree.shownCommands(all, isRunning: running) == all)
        #expect(BranchSituation.main.shownCommands(all, isRunning: running) == all)
        for situation in [BranchSituation.inactive, .blocked, .missing] {
            #expect(situation.shownCommands(all, isRunning: running) == [queue])
            #expect(situation.shownCommands(all) { _ in false }.isEmpty) // sin nada corriendo, no hay sección
        }
    }
}
