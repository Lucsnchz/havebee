import Foundation
import HiveCore

/// Alerta con una acción opcional (ej. "Borrar igual").
public struct AppAlert: Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
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
