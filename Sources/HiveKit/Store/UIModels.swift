import Foundation
import HiveCore

/// Alerta con una acción opcional (ej. "Borrar igual").
public struct AppAlert: Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String
    public var actionTitle: String?
    public var action: (() -> Void)?
    /// La acción borra o corta algo («Borrar igual», «Archivar igual»): el botón va en rojo.
    public var isDestructive: Bool
    /// Botón que cierra sin hacer nada (por defecto «Cancelar» si hay acción, «OK» si no).
    public var cancelTitle: String?

    public init(title: String, message: String, actionTitle: String? = nil, isDestructive: Bool = false,
                cancelTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.isDestructive = isDestructive
        self.cancelTitle = cancelTitle
        self.action = action
    }
}

/// Algo que se puede deshacer por unos segundos: la cápsula de abajo al centro y ⌘Z.
public struct UndoAction: Identifiable {
    public let id = UUID()
    /// «Archivaste “Claude 2”».
    public let message: String
    public let expiresAt: Date
    let undo: () -> Void
}

/// Qué hacer después de un checkout que se pidió para abrir algo.
public enum AfterCheckout: Equatable {
    case createSession(SessionKind)
    case openSession(UUID)
    case nothing
}

public struct PendingCheckout: Identifiable {
    public let id = UUID()
    public let branchId: UUID
    public let branchName: String
    public let currentHead: String
    public let after: AfterCheckout
    /// Sesiones abiertas en otras ramas de la carpeta principal (van a ver el cambio).
    public let runningElsewhere: Int
    /// Hay cambios sin commitear en la carpeta principal.
    public let dirty: Bool

    /// Texto del diálogo de confirmación.
    public var message: String {
        let head = currentHead.isEmpty ? "un commit suelto (HEAD desacoplado)" : "«\(currentHead)»"
        var text = "La carpeta principal está en \(head). Esta rama no tiene worktree, así que para trabajar en ella hay que cambiar la carpeta principal."
        if dirty {
            text += "\n\nHay cambios sin commitear: git los lleva a la nueva rama, o cancela el checkout si chocan."
        }
        if runningElsewhere > 0 {
            text += "\n\n\(runningElsewhere == 1 ? "Una sesión abierta" : "\(runningElsewhere) sesiones abiertas") en otras ramas de la carpeta principal van a quedar viendo esta rama."
        }
        return text
    }
}

public struct PendingRemoval: Identifiable {
    public let id = UUID()
    public let item: SidebarItem
    public let title: String
    public let message: String
    public let isWorktree: Bool
}

public struct RenameRequest: Identifiable {
    public let id = UUID()
    public let item: SidebarItem
}

public struct NewBranchTarget: Identifiable {
    public let id: UUID // proyecto
}

public struct CustomizeTarget: Identifiable {
    public let id: UUID // proyecto
}

public struct MCPEditorTarget: Identifiable {
    public let id = UUID()
    public let projectId: UUID
    /// nil para uno nuevo.
    public let serverName: String?
}

public struct CommandEditorTarget: Identifiable {
    public let id = UUID()
    public let projectId: UUID
    public let commandId: UUID?
}

/// Archivos para el visor de diffs y cuál está abierto.
public struct DiffTarget: Identifiable {
    public struct File: Hashable {
        public let change: GitChange
        public let staged: Bool
    }

    public let id = UUID()
    public let directory: String
    public let files: [File]
    public var selected: Int

    /// Preparados primero y después los cambios, como en la lista; abre en `change`.
    public static func make(directory: String, status: GitStatus, change: GitChange, staged: Bool) -> DiffTarget {
        let files = status.changes.filter(\.isStaged).map { File(change: $0, staged: true) }
            + status.changes.filter(\.isUnstaged).map { File(change: $0, staged: false) }
        let index = files.firstIndex(of: File(change: change, staged: staged)) ?? 0
        return DiffTarget(directory: directory, files: files, selected: index)
    }
}
