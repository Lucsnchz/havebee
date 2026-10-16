import Foundation
import HiveCore

/// Una operación con el remoto de una rama (publicar, traer) que está corriendo.
public struct RemoteOperation {
    let id: UUID
    /// Lo que se está haciendo («Publicando…»), para el spinner.
    public let label: String
    let task: Task<Void, Never>?
}

/// Publicar y traer: corren fuera del hilo principal y se pueden cancelar. Viven en el store y no en
/// la barra de la sesión, que se arma de nuevo cada vez que cambiás de sesión o de rama: con un
/// pre-push que tarda minutos, al volver tiene que seguir el spinner con su X, y no se tiene que
/// poder lanzar otro push encima del que corre.
extension AppStore {
    /// Corre `work` (con el git del store, la carpeta y el nombre de la rama). Hay una sola por rama:
    /// si ya corre otra, no arranca y devuelve nil. Si sale bien llama a `success`; si falla, avisa con
    /// una alerta, y si la cancelaste (`cancelRemoteOperation`), con un aviso corto.
    @discardableResult
    func runRemoteOperation(branchId: UUID, directory: String, branchName: String, label: String,
                            failureTitle: String, cancelledNotice: String,
                            _ work: @escaping @Sendable (GitClient, String, String) -> CommandResult,
                            then success: (() -> Void)? = nil) -> Task<Void, Never>? {
        guard remoteOperations[branchId] == nil else { return nil }
        let git = self.git
        let id = UUID()
        let task = Task { [weak self] in
            let result = await CancellableWork.run { work(git, directory, branchName) }
            guard let self else { return }
            if self.remoteOperations[branchId]?.id == id { self.remoteOperations[branchId] = nil }
            if result.ok {
                success?()
            } else if result.cancelled {
                self.showNotice(cancelledNotice)
            } else {
                self.alert = AppAlert(title: failureTitle,
                                      message: result.errorMessage.isEmpty ? "git terminó con el código \(result.status)." : result.errorMessage)
            }
            self.refreshGit()
        }
        // La tarea arranca recién cuando se libera el hilo principal: ya encuentra esto anotado.
        remoteOperations[branchId] = RemoteOperation(id: id, label: label, task: task)
        return task
    }

    /// La X junto al spinner: corta git y lo que lanzó (un hook pre-push, ssh).
    func cancelRemoteOperation(branchId: UUID) {
        remoteOperations[branchId]?.task?.cancel()
    }
}
