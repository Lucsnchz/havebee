import Foundation

/// Qué corre dentro de una sesión.
public enum SessionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini, grok, shell

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .shell: "Terminal"
        }
    }

    public var defaultName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .shell: "Terminal"
        }
    }

    /// Ejecutable que se lanza (nil para la terminal, que usa tu shell).
    public var binary: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .grok: "grok"
        case .shell: nil
        }
    }

    public var installHint: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        case .gemini: "npm install -g @google/gemini-cli"
        case .grok: "curl -fsSL https://x.ai/cli/install.sh | bash"
        case .shell: ""
        }
    }

    public var isAgent: Bool { self != .shell }

    /// Agentes que avisan a Hive lo que hablan (hooks de Claude, notify de Codex).
    public var reportsConversation: Bool { self == .claude || self == .codex }
}

public struct Session: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: SessionKind
    public var createdAt: Date
    /// Conversación del agente para poder reanudarla.
    /// Claude y Grok: el UUID que le pasamos con --session-id. Codex: el thread-id que reporta su notify.
    public var agentSessionId: String?
    public var lastLaunchedAt: Date?
    /// Lo último que respondió el agente (resumido), para mostrarlo en la tarjeta de la sesión.
    public var lastMessage: String?
    public var lastActivityAt: Date?
    /// Si tiene fecha, la sesión está archivada: no aparece en el sidebar ni en las pestañas,
    /// pero conserva su conversación para restaurarla.
    public var archivedAt: Date?
    /// Si el nombre lo pone Hive (nil cuenta como sí): la sesión toma el nombre de lo primero que le
    /// pedís. Al renombrarla a mano pasa a false y Hive no lo vuelve a tocar.
    public var autoNamed: Bool?
    /// La IA anterior de esta conversación. El nuevo agente recibe el historial compartido al arrancar.
    public var handoffFrom: SessionKind?
    /// Trabajo confirmado que todavía no terminó. Sobrevive a un cierre o caída de Hive.
    public var pendingWork: PendingAgentWork?
    /// Texto que el agente devolvió como no enviado al fallar. Se conserva aparte del historial:
    /// todavía no es una tarea recibida por la IA, y nunca se manda automáticamente.
    public var recoveredDraft: String?

    public init(id: UUID = UUID(), name: String, kind: SessionKind, createdAt: Date = Date(),
                agentSessionId: String? = nil, lastLaunchedAt: Date? = nil, lastMessage: String? = nil,
                lastActivityAt: Date? = nil, archivedAt: Date? = nil, autoNamed: Bool? = nil,
                handoffFrom: SessionKind? = nil, pendingWork: PendingAgentWork? = nil, recoveredDraft: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.agentSessionId = agentSessionId
        self.lastLaunchedAt = lastLaunchedAt
        self.lastMessage = lastMessage
        self.lastActivityAt = lastActivityAt
        self.archivedAt = archivedAt
        self.autoNamed = autoNamed
        self.handoffFrom = handoffFrom
        self.pendingWork = pendingWork
        self.recoveredDraft = recoveredDraft
    }

    public var isArchived: Bool { archivedAt != nil }

    /// Para ordenar por uso reciente.
    public var recency: Date { lastActivityAt ?? lastLaunchedAt ?? createdAt }

    /// La última vez que la usaste: que le escribiste (o que el agente terminó algo), o que la
    /// creaste. Que se lance no cuenta: abrir una sesión dormida la lanza, y mirarla no es usarla.
    public var lastUsedAt: Date { lastActivityAt ?? createdAt }
}

/// Un comando guardado del proyecto (ej. `npm run dev`).
public struct ProjectCommand: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String

    public init(id: UUID = UUID(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

/// Dónde vive una rama: en la carpeta principal del repo (checkout) o en un worktree propio.
public enum BranchMode: String, Codable, Sendable {
    case main, worktree
}

public struct Branch: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: BranchMode
    public var worktreePath: String?
    public var sessions: [Session]
    /// Si es nil, la rama usa el color del proyecto.
    public var color: TintColor?

    /// Preparación pendiente o fallida; se conserva para poder reintentar después de reabrir Hive.
    public var setupCommand: String?
    public var setupFirstSession: SessionKind?
    /// Alias de Herd creado por la preparación automática de este worktree.
    public var herdSite: String?

    public init(id: UUID = UUID(), name: String, mode: BranchMode, worktreePath: String? = nil,
                sessions: [Session] = [], color: TintColor? = nil) {
        self.id = id
        self.name = name
        self.mode = mode
        self.worktreePath = worktreePath
        self.sessions = sessions
        self.color = color
    }

    public var activeSessions: [Session] { sessions.filter { !$0.isArchived } }
    public var archivedSessions: [Session] { sessions.filter(\.isArchived) }
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var branches: [Branch]
    /// Worktrees que quitaste de Hive a propósito: la detección automática no los vuelve a agregar.
    public var ignoredWorktrees: [String]
    public var color: TintColor?
    public var icon: ProjectIcon?
    public var commands: [ProjectCommand]
    /// El proyecto especial «Terminales»: tu carpeta personal, sin git, para terminales sueltas.
    public var isScratch: Bool
    /// Fijado arriba en el riel y en el árbol (clic derecho › «Fijar arriba»), use o no hoy.
    public var pinned: Bool

    public init(id: UUID = UUID(), name: String, path: String, branches: [Branch] = [],
                ignoredWorktrees: [String] = [], color: TintColor? = nil, icon: ProjectIcon? = nil,
                commands: [ProjectCommand] = [], isScratch: Bool = false, pinned: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.branches = branches
        self.ignoredWorktrees = ignoredWorktrees
        self.color = color
        self.icon = icon
        self.commands = commands
        self.isScratch = isScratch
        self.pinned = pinned
    }

    public var activeSessions: [Session] { branches.flatMap(\.activeSessions) }
    public var allSessions: [Session] { branches.flatMap(\.sessions) }

    public func directory(for branch: Branch) -> String {
        branch.mode == .worktree ? (branch.worktreePath ?? path) : path
    }

    public var tint: TintColor { color ?? .blue }

    /// Dos letras para el ícono: las iniciales de las dos primeras palabras ("dizeg-kotlin" → "DK")
    /// o las dos primeras letras si es una sola ("ecommerce" → "EC").
    public var initials: String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.count >= 2 { return (words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String((words.first ?? name).prefix(2)).uppercased()
    }

    /// El proyecto «Terminales».
    public static func scratch(home: String) -> Project {
        Project(name: "Terminales", path: home, branches: [Branch(name: "~", mode: .main)],
                color: .gray, icon: .symbol("terminal.fill"), isScratch: true)
    }
}

extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, name, path, branches, ignoredWorktrees, color, icon, commands, isScratch, pinned
    }

    /// Lee estados guardados por versiones anteriores de Hive (sin los campos nuevos).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        branches = try c.decode([Branch].self, forKey: .branches)
        ignoredWorktrees = try c.decodeIfPresent([String].self, forKey: .ignoredWorktrees) ?? []
        color = try c.decodeIfPresent(TintColor.self, forKey: .color)
        icon = try c.decodeIfPresent(ProjectIcon.self, forKey: .icon)
        commands = try c.decodeIfPresent([ProjectCommand].self, forKey: .commands) ?? []
        isScratch = try c.decodeIfPresent(Bool.self, forKey: .isScratch) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// Paleta para distinguir proyectos y ramas.
public enum TintColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue, orange, green, purple, pink, teal, amber, red, indigo, cyan, lime, gray

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .blue: "Azul"
        case .orange: "Naranja"
        case .green: "Verde"
        case .purple: "Violeta"
        case .pink: "Rosa"
        case .teal: "Turquesa"
        case .amber: "Miel"
        case .red: "Rojo"
        case .indigo: "Índigo"
        case .cyan: "Celeste"
        case .lime: "Lima"
        case .gray: "Gris"
        }
    }

    public var rgb: (Double, Double, Double) {
        switch self {
        case .blue: (0.30, 0.55, 0.96)
        case .orange: (0.96, 0.53, 0.23)
        case .green: (0.20, 0.76, 0.47)
        case .purple: (0.65, 0.42, 0.94)
        case .pink: (0.93, 0.37, 0.65)
        case .teal: (0.16, 0.73, 0.67)
        case .amber: (0.96, 0.72, 0.24)
        case .red: (0.94, 0.33, 0.35)
        case .indigo: (0.42, 0.42, 0.94)
        case .cyan: (0.22, 0.70, 0.91)
        case .lime: (0.58, 0.79, 0.23)
        case .gray: (0.55, 0.55, 0.60)
        }
    }
}

/// Cómo se dibuja el ícono de un proyecto.
public enum ProjectIcon: Codable, Hashable, Sendable {
    case initials
    case symbol(String)
    case emoji(String)
    /// Ruta a una imagen: el logo detectado en el repo o una elegida por vos.
    case image(String)
}

public enum SidebarItem: Hashable, Codable, Sendable {
    case project(UUID)
    case branch(UUID)
    case session(UUID)
}

/// Lo que se guarda en disco entre ejecuciones.
public struct HiveState: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var selection: SidebarItem?
    public var expanded: [UUID]
    /// Última sesión abierta en cada proyecto (para volver a ella al elegir el proyecto).
    public var lastSessions: [UUID: UUID]?
    /// Rama que tenía la carpeta principal de cada repo ("" si HEAD estaba desacoplado), para no
    /// leer git al arrancar. Los estados viejos no la tienen.
    public var mainHeads: [UUID: String]?

    public init(projects: [Project], selection: SidebarItem? = nil, expanded: [UUID] = [], lastSessions: [UUID: UUID]? = nil,
                mainHeads: [UUID: String]? = nil) {
        self.projects = projects
        self.selection = selection
        self.expanded = expanded
        self.lastSessions = lastSessions
        self.mainHeads = mainHeads
    }
}

/// Cuántas sesiones de un grupo están en cada estado (para el borde de los íconos).
public struct Activity: Equatable, Sendable {
    public var working: Int
    public var pending: Int
    public var attention: Int

    public init(working: Int = 0, pending: Int = 0, attention: Int = 0) {
        self.working = working
        self.pending = pending
        self.attention = attention
    }

    public enum Ring: Sendable { case none, working, pending, attention }

    public var ring: Ring {
        if attention > 0 { return .attention }
        if pending > 0 { return .pending }
        if working > 0 { return .working }
        return .none
    }

    public var waitingForYou: Int { pending + attention }
}
