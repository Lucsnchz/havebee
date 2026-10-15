import AppKit
import HiveCore
import SwiftUI

/// Los menús de Hive: «Sesión» e «Ir», y lo que se suma a Archivo, Edición y Visualización.
/// Todo se puede hacer con el teclado; los atajos están en `Shortcut` para que un test verifique
/// que no se repitan.
struct HiveCommands: Commands {
    let store: AppStore
    @AppStorage("layout") private var layout: HiveLayout = .tree
    @AppStorage("sessionSidePanel") private var sidePanel = ""
    @AppStorage(FontSize.key) private var fontSize = FontSize.standard

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Agregar proyecto…") { store.addProjectInteractive() }
                .hiveShortcut(.addProject)
        }
        // Reemplaza «Cerrar» y «Cerrar todo»: ⌘W pasa a «Archivar» (que en otras ventanas cierra).
        CommandGroup(replacing: .saveItem) {
            Button("Cerrar ventana") { NSApp.keyWindow?.performClose(nil) }
                .hiveShortcut(.closeWindow)
        }
        CommandGroup(after: .textEditing) {
            findItems
        }
        CommandGroup(before: .sidebar) {
            Picker("Vista", selection: $layout) {
                Text("Árbol").tag(HiveLayout.tree)
                Text("Compacta").tag(HiveLayout.compact)
            }
            .pickerStyle(.inline)
            // (el selector en línea ya trae sus separadores)
            Button("Agrandar texto") { FontSize.change(by: 1) }
                .hiveShortcut(.zoomIn)
                .disabled(fontSize >= FontSize.range.upperBound)
            Button("Achicar texto") { FontSize.change(by: -1) }
                .hiveShortcut(.zoomOut)
                .disabled(fontSize <= FontSize.range.lowerBound)
            Button("Tamaño real") { FontSize.reset() }
                .hiveShortcut(.actualSize)
                .disabled(fontSize == FontSize.standard)
            Divider()
        }
        CommandMenu("Sesión") {
            sessionItems
        }
        CommandMenu("Ir") {
            goItems
        }
    }

    // MARK: Sesión

    @ViewBuilder private var sessionItems: some View {
        let target = HiveNavigator.newSessionTarget(store)
        let project = store.currentProjectId.flatMap(store.project)
        let selected = HiveNavigator.selectedSession(store)
        let runtime = selected.flatMap { store.runtimes[$0.session.id] }
        Button(target.map { "Nueva sesión de \($0.kind.defaultName)" } ?? "Nueva sesión") {
            HiveNavigator.newSession(store)
        }
        .hiveShortcut(.newSession)
        .disabled(target == nil)
        Menu("Nueva sesión de…") {
            ForEach(SessionKind.allCases) { kind in
                Button {
                    HiveNavigator.newSession(store, kind: kind)
                } label: {
                    Label { Text(kind.label) } icon: { Image(nsImage: AgentLogo.menuImage(kind)) }
                }
            }
        }
        .disabled(target == nil)
        Button("Nueva rama…") {
            if let project, !project.isScratch { store.newBranchTarget = NewBranchTarget(id: project.id) }
        }
        .hiveShortcut(.newBranch)
        .disabled(project == nil || project?.isScratch == true)
        Divider()
        Button(runtime?.status.isExited == true ? "Reanudar" : "Reiniciar") {
            if let id = selected?.session.id { store.relaunch(id) }
        }
        .hiveShortcut(.restart)
        .disabled(!(runtime?.isRunning == true || runtime?.status.isExited == true))
        Button("Detener") { HiveNavigator.stopOrCancel(store) }
        .hiveShortcut(.stop)
        .disabled(runtime?.isRunning != true)
        Divider()
        Button("Renombrar…") {
            if let id = selected?.session.id { store.beginRename(.session(id)) }
        }
        .disabled(selected == nil)
        Button("Archivar") { HiveNavigator.archiveOrClose(store) }
            .hiveShortcut(.archive)
        Divider()
        Toggle("Historial", isOn: panel("history"))
            .hiveShortcut(.history)
            .disabled(selected == nil)
        Toggle("Cambios", isOn: panel("changes"))
            .hiveShortcut(.changes)
            .disabled(selected == nil || selected?.project.isScratch == true)
    }

    private func panel(_ name: String) -> Binding<Bool> {
        Binding(get: { sidePanel == name }, set: { sidePanel = $0 ? name : "" })
    }

    // MARK: Ir

    @ViewBuilder private var goItems: some View {
        let project = store.currentProjectId.flatMap(store.project)
        let (tabs, showBranch) = project.map(ProjectTabs.make) ?? ([], false)
        Button("Inicio") { store.select(nil) }
            .hiveShortcut(.home)
        Button("Buscar…") { store.showSwitcher = true }
            .hiveShortcut(.search)
        Divider()
        Button("Siguiente que te espera") {
            if !HiveNavigator.goToNextWaiting(store) { NSSound.beep() }
        }
        .hiveShortcut(.nextWaiting)
        // Sin Section: dos secciones seguidas dejan dos separadores juntos en el menú.
        Divider()
        Button("Sesión siguiente") { HiveNavigator.goToAdjacentSession(store, delta: 1) }
            .hiveShortcut(.nextSession)
            .disabled(tabs.isEmpty)
        Button("Sesión anterior") { HiveNavigator.goToAdjacentSession(store, delta: -1) }
            .hiveShortcut(.previousSession)
            .disabled(tabs.isEmpty)
        // Las pestañas del proyecto abierto (⌘1…⌘9).
        ForEach(Array(tabs.prefix(Shortcut.tabs.count).enumerated()), id: \.element.id) { index, tab in
            Button(showBranch ? "\(tab.session.name) · \(tab.branch.name)" : tab.session.name) {
                HiveNavigator.goToTab(store, index: index)
            }
            .hiveShortcut(Shortcut.tabs[index])
        }
        Divider()
        Button("Proyecto siguiente") { HiveNavigator.goToAdjacentProject(store, delta: 1) }
            .hiveShortcut(.nextProject)
        Button("Proyecto anterior") { HiveNavigator.goToAdjacentProject(store, delta: -1) }
            .hiveShortcut(.previousProject)
        // Los proyectos en el orden del sidebar (⌃⌘1…⌃⌘9).
        ForEach(Array(store.projects.prefix(Shortcut.projects.count).enumerated()), id: \.element.id) { index, project in
            Button(project.name) { HiveNavigator.goToProject(store, index: index) }
                .hiveShortcut(Shortcut.projects[index])
        }
    }

    // MARK: Edición

    @ViewBuilder private var findItems: some View {
        let selected = HiveNavigator.selectedSession(store)
        let hasTerminal = selected != nil || !store.commandRuns.isEmpty
        Menu("Buscar") {
            Button("Buscar en la terminal…") { HiveNavigator.find(.showFindInterface, store: store) }
                .hiveShortcut(.find)
            Button("Buscar siguiente") { HiveNavigator.find(.nextMatch, store: store) }
                .hiveShortcut(.findNext)
            Button("Buscar anterior") { HiveNavigator.find(.previousMatch, store: store) }
                .hiveShortcut(.findPrevious)
            Button("Usar la selección para buscar") { HiveNavigator.find(.setSearchString, store: store) }
                .hiveShortcut(.useSelection)
        }
        .disabled(!hasTerminal)
        // En los agentes se limpia con /clear (así el historial queda en el panel).
        Button("Limpiar terminal") {
            if !HiveNavigator.clearTerminal(store) { NSSound.beep() }
        }
        .hiveShortcut(.clearTerminal)
        .disabled(selected.map { $0.session.kind.isAgent } ?? store.commandRuns.isEmpty)
    }
}

// MARK: - Atajos

extension HiveCommands {
    /// Un atajo de teclado de los menús.
    struct Shortcut: Hashable, CustomStringConvertible {
        let name: String
        let key: KeyEquivalent
        let modifiers: EventModifiers

        init(_ name: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command) {
            self.name = name
            self.key = key
            self.modifiers = modifiers
        }

        static func == (a: Shortcut, b: Shortcut) -> Bool { a.signature == b.signature }
        func hash(into hasher: inout Hasher) { hasher.combine(signature) }

        /// Tecla y modificadores: dos atajos con la misma firma chocan.
        var signature: String { "\(modifiers.rawValue)-\(key.character)" }

        /// Como lo muestra macOS en los menús: ⌃⌥⇧⌘ y la tecla.
        var description: String {
            var text = ""
            if modifiers.contains(.control) { text += "⌃" }
            if modifiers.contains(.option) { text += "⌥" }
            if modifiers.contains(.shift) { text += "⇧" }
            if modifiers.contains(.command) { text += "⌘" }
            switch key {
            case .upArrow: text += "↑"
            case .downArrow: text += "↓"
            case .leftArrow: text += "←"
            case .rightArrow: text += "→"
            default: text += String(key.character).uppercased()
            }
            return text
        }

        static let addProject = Shortcut("Agregar proyecto", "o")
        static let closeWindow = Shortcut("Cerrar ventana", "w", [.command, .shift])
        static let newSession = Shortcut("Nueva sesión", "t")
        static let newBranch = Shortcut("Nueva rama", "n", [.command, .shift])
        static let restart = Shortcut("Reiniciar", "r")
        static let stop = Shortcut("Detener", ".")
        static let archive = Shortcut("Archivar", "w")
        static let history = Shortcut("Historial", "1", [.command, .option])
        static let changes = Shortcut("Cambios", "2", [.command, .option])
        static let home = Shortcut("Inicio", "h", [.command, .shift])
        static let search = Shortcut("Buscar", "k")
        static let nextWaiting = Shortcut("Siguiente que te espera", "j")
        static let nextSession = Shortcut("Sesión siguiente", "]", [.command, .shift])
        static let previousSession = Shortcut("Sesión anterior", "[", [.command, .shift])
        static let nextProject = Shortcut("Proyecto siguiente", .downArrow, [.command, .option])
        static let previousProject = Shortcut("Proyecto anterior", .upArrow, [.command, .option])
        static let find = Shortcut("Buscar en la terminal", "f")
        static let findNext = Shortcut("Buscar siguiente", "g")
        static let findPrevious = Shortcut("Buscar anterior", "g", [.command, .shift])
        static let useSelection = Shortcut("Usar la selección para buscar", "e")
        static let clearTerminal = Shortcut("Limpiar terminal", "k", [.command, .option])
        static let zoomIn = Shortcut("Agrandar texto", "+")
        /// ⌘= hace lo mismo que ⌘+ (en un teclado de EE. UU. el + necesita Shift). No tiene ítem
        /// propio en el menú: lo atiende `handleKeyDown`.
        static let zoomInAlternate = Shortcut("Agrandar texto (=)", "=")
        static let zoomOut = Shortcut("Achicar texto", "-")
        static let actualSize = Shortcut("Tamaño real", "0")
        /// ⌘1…⌘9: pestañas del proyecto abierto.
        static let tabs = (1...9).map { Shortcut("Pestaña \($0)", KeyEquivalent(Character("\($0)"))) }
        /// ⌃⌘1…⌃⌘9: proyectos en el orden del sidebar.
        static let projects = (1...9).map { Shortcut("Proyecto \($0)", KeyEquivalent(Character("\($0)")), [.command, .control]) }

        /// ⌘N de la pestaña en `index` (desde 0), si es una de las nueve primeras.
        static func tab(_ index: Int) -> Shortcut? { tabs.indices.contains(index) ? tabs[index] : nil }

        /// ⌃⌘N del proyecto en `index` (desde 0), si es uno de los nueve primeros.
        static func project(_ index: Int) -> Shortcut? { projects.indices.contains(index) ? projects[index] : nil }

        /// Todos los atajos de Hive.
        static let all: [Shortcut] = [
            addProject, closeWindow, newSession, newBranch, restart, stop, archive, history, changes,
            home, search, nextWaiting, nextSession, previousSession, nextProject, previousProject,
            find, findNext, findPrevious, useSelection, clearTerminal, zoomIn, zoomInAlternate, zoomOut, actualSize,
        ] + tabs + projects

        /// Atajos de macOS que Hive no reemplaza: ninguno de los nuestros puede coincidir.
        static let system: [Shortcut] = [
            Shortcut("Salir", "q"), Shortcut("Ocultar", "h"), Shortcut("Ocultar otras", "h", [.command, .option]),
            Shortcut("Minimizar", "m"), Shortcut("Ajustes", ","), Shortcut("Deshacer", "z"),
            Shortcut("Rehacer", "z", [.command, .shift]), Shortcut("Cortar", "x"), Shortcut("Copiar", "c"),
            Shortcut("Pegar", "v"), Shortcut("Seleccionar todo", "a"), Shortcut("Ayuda", "?"),
            Shortcut("Pantalla completa", "f", [.command, .control]), Shortcut("Barra lateral", "s", [.command, .control]),
            Shortcut("Barra lateral (oculto)", "s", [.command, .option]), Shortcut("Barra de herramientas", "t", [.command, .option]),
            Shortcut("Cambiar de ventana", "`"), Shortcut("Emoji", " "), Shortcut("Emoji (oculto)", " ", [.command, .control]),
        ]
    }
}

extension View {
    /// Asigna un atajo de la tabla de Hive.
    fileprivate func hiveShortcut(_ shortcut: HiveCommands.Shortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}

// MARK: - Tamaño de letra de la terminal

extension HiveCommands {
    /// El tamaño de letra de las terminales (UserDefaults `terminalFontSize`): lo leen las terminales.
    enum FontSize {
        static let key = "terminalFontSize"
        static let standard: Double = 13
        static let range: ClosedRange<Double> = 9...28

        static func current(_ defaults: UserDefaults = .standard) -> Double {
            let value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? standard
            return min(max(value, range.lowerBound), range.upperBound)
        }

        /// Un punto más o menos, sin salir del rango.
        static func stepped(_ size: Double, by delta: Double) -> Double {
            min(max((size + delta).rounded(), range.lowerBound), range.upperBound)
        }

        static func change(by delta: Double, defaults: UserDefaults = .standard) {
            defaults.set(stepped(current(defaults), by: delta), forKey: key)
        }

        static func reset(defaults: UserDefaults = .standard) {
            defaults.set(standard, forKey: key)
        }
    }

    /// Antes de cada atajo con ⌘: refresca los menús y atiende ⌘=.
    ///
    /// SwiftUI arma los menús principales recién cuando se abren, así que un ítem que se habilitó
    /// (o una pestaña nueva para ⌘1…⌘9) no respondería a su atajo hasta abrir el menú. Pedirles
    /// que se actualicen antes de que AppKit busque el atajo lo resuelve.
    /// Devuelve true si ya se ocupó del evento (y no hay que seguir pasándolo).
    static func handleKeyDown(_ event: NSEvent, defaults: UserDefaults = .standard) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return false }
        if flags == .command && event.charactersIgnoringModifiers == String(Shortcut.zoomInAlternate.key.character) {
            FontSize.change(by: 1, defaults: defaults)
            return true
        }
        refreshMenus()
        return false
    }

    static func refreshMenus() {
        guard let menu = NSApp?.mainMenu else { return }
        for item in menu.items {
            if let submenu = item.submenu { submenu.delegate?.menuNeedsUpdate?(submenu) }
        }
    }
}

// MARK: - Acciones

/// Lo que hacen los menús, separado de las vistas para poder probarlo con un store de prueba.
@MainActor
enum HiveNavigator {
    /// La sesión abierta, si la selección es una sesión.
    static func selectedSession(_ store: AppStore) -> (project: Project, branch: Branch, session: Session)? {
        guard case .session(let id)? = store.selection else { return nil }
        return store.sessionContext(id)
    }

    /// Dónde y de qué agente es la sesión que crea ⌘T: el de la sesión abierta (o Claude), en la
    /// rama de la selección o en la rama por defecto del proyecto.
    static func newSessionTarget(_ store: AppStore) -> (branchId: UUID, kind: SessionKind)? {
        guard let projectId = store.currentProjectId, let project = store.project(projectId) else { return nil }
        let kind = selectedSession(store)?.session.kind ?? .claude
        guard let branch = store.defaultBranch(for: project) else { return nil }
        return (branch.id, kind)
    }

    static func newSession(_ store: AppStore, kind: SessionKind? = nil) {
        guard let target = newSessionTarget(store) else { return }
        store.requestNewSession(branchId: target.branchId, kind: kind ?? target.kind)
    }

    /// Qué hace ⌘W.
    enum CloseDecision: Equatable {
        case archive(UUID)
        case closeWindow
    }

    /// En la ventana principal, sin hojas abiertas y con una sesión abierta, ⌘W la archiva; en
    /// cualquier otro caso (Ajustes, una hoja, el Resumen) se comporta como «Cerrar».
    static func closeDecision(selection: SidebarItem?, keyWindowIsMain: Bool, sheetOpen: Bool) -> CloseDecision {
        if keyWindowIsMain, !sheetOpen, case .session(let id)? = selection { return .archive(id) }
        return .closeWindow
    }

    static func archiveOrClose(_ store: AppStore) {
        let window = NSApp?.keyWindow
        switch closeDecision(selection: store.selection, keyWindowIsMain: isMain(window), sheetOpen: window?.attachedSheet != nil) {
        case .archive(let id): store.requestArchive(id)
        case .closeWindow: window?.performClose(nil)
        }
    }

    /// Qué hace «Detener» (⌘.).
    enum StopDecision: Equatable {
        case stop(UUID)
        /// En una hoja (el buscador, renombrar…) o en otra ventana, ⌘. es «Cancelar», como en todo
        /// macOS: cortar la sesión que quedó detrás sería una sorpresa fea.
        case cancel
    }

    static func stopDecision(selection: SidebarItem?, keyWindowIsMain: Bool, sheetOpen: Bool) -> StopDecision {
        if keyWindowIsMain, !sheetOpen, case .session(let id)? = selection { return .stop(id) }
        return .cancel
    }

    static func stopOrCancel(_ store: AppStore) {
        let window = NSApp?.keyWindow
        switch stopDecision(selection: store.selection, keyWindowIsMain: isMain(window), sheetOpen: window?.attachedSheet != nil) {
        case .stop(let id): store.stop(id)
        case .cancel:
            // Por el mismo camino que esc: así un campo de texto se lo avisa a su vista (onExitCommand).
            window?.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        }
    }

    /// Si la ventana es la principal de Hive (y no Ajustes, una hoja u otra).
    private static func isMain(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == HiveApplication.mainWindowId
    }

    /// Abre una sesión y despliega su proyecto y su rama en el árbol.
    static func reveal(_ store: AppStore, session id: UUID) {
        guard let ctx = store.sessionContext(id) else { return }
        store.setExpanded(ctx.project.id, true)
        if !ctx.project.isScratch { store.setExpanded(ctx.branch.id, true) }
        store.select(.session(id))
    }

    /// Abre una sesión en un mensaje de su historial (lo que encontró «?» en ⌘K): el panel lateral
    /// pasa a «Historial» y salta a esa entrada. Una archivada no se abre (devuelve false): queda
    /// pedido el salto y el buscador muestra su historial en la misma hoja.
    @discardableResult
    static func openHistoryEntry(_ store: AppStore, session id: UUID, entry: UUID, query: String,
                                 jumps: HistoryJumpRequest? = nil, defaults: UserDefaults = .standard) -> Bool {
        guard let ctx = store.sessionContext(id) else { return false }
        (jumps ?? .shared).pending = .init(sessionId: id, entryId: entry, query: query)
        guard !ctx.session.isArchived else { return false }
        defaults.set("history", forKey: "sessionSidePanel")
        reveal(store, session: id)
        return true
    }

    /// Abre un proyecto (en su última sesión) y lo despliega en el árbol.
    static func open(_ store: AppStore, project id: UUID) {
        store.openProject(id)
        store.setExpanded(id, true)
        if case .session(let sessionId)? = store.selection, let ctx = store.sessionContext(sessionId), !ctx.project.isScratch {
            store.setExpanded(ctx.branch.id, true)
        }
    }

    static func goToTab(_ store: AppStore, index: Int) {
        guard let id = store.currentProjectId, let project = store.project(id) else { return }
        let tabs = ProjectTabs.make(project).tabs
        guard tabs.indices.contains(index) else { return }
        reveal(store, session: tabs[index].session.id)
    }

    static func goToProject(_ store: AppStore, index: Int) {
        guard store.projects.indices.contains(index) else { return }
        open(store, project: store.projects[index].id)
    }

    static func goToAdjacentSession(_ store: AppStore, delta: Int) {
        guard let id = store.currentProjectId, let project = store.project(id),
              let next = SessionNavigation.adjacentSession(of: selectedSession(store)?.session.id, delta: delta, in: project) else { return }
        reveal(store, session: next)
    }

    static func goToAdjacentProject(_ store: AppStore, delta: Int) {
        guard let next = SessionNavigation.adjacentProject(of: store.currentProjectId, delta: delta, in: store.projects) else { return }
        open(store, project: next)
    }

    /// Las sesiones activas que podrían estar esperándote.
    static func waitingCandidates(_ store: AppStore) -> [WaitingCandidate] {
        store.projects.flatMap(\.activeSessions).compactMap { session in
            guard let rt = store.runtimes[session.id] else { return nil }
            return WaitingCandidate(sessionId: session.id, needsPermission: rt.status == .attention,
                                    unseen: rt.unseen, lastActivityAt: session.lastActivityAt)
        }
    }

    /// Va a la sesión que más te necesita. Devuelve false si no hay ninguna.
    @discardableResult
    static func goToNextWaiting(_ store: AppStore) -> Bool {
        guard let id = SessionNavigation.nextWaiting(candidates: waitingCandidates(store),
                                                     excluding: selectedSession(store)?.session.id) else { return false }
        reveal(store, session: id)
        return true
    }

    /// Limpia la terminal con foco o, si el foco está en otro lado de la misma ventana (el sidebar,
    /// por ejemplo), la de la sesión abierta. Devuelve si limpió algo (los agentes no se limpian así:
    /// se usa /clear y el historial queda en el panel).
    @discardableResult
    static func clearTerminal(_ store: AppStore, keyWindow: NSWindow? = NSApp?.keyWindow) -> Bool {
        let selector = #selector(HiveTerminalView.clearTerminal(_:))
        if keyWindow?.firstResponder is HiveTerminalView {
            return NSApp.sendAction(selector, to: nil, from: nil)
        }
        if let id = selectedSession(store)?.session.id, let terminal = store.runtimes[id]?.terminal,
           let window = terminal.window, window === keyWindow {
            guard !terminal.preservesScrollbackOnClear else { return false }
            terminal.clearTerminal(nil)
            return true
        }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// Busca en la terminal con foco o, si el foco está en otro lado de la ventana principal, en la
    /// de la sesión abierta. En una hoja o en Ajustes no le saca el foco a la ventana de atrás.
    static func find(_ action: NSTextFinder.Action, store: AppStore) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        let selector = #selector(NSResponder.performTextFinderAction(_:))
        if NSApp.keyWindow?.firstResponder is HiveTerminalView {
            NSApp.sendAction(selector, to: nil, from: sender)
            return
        }
        if let id = selectedSession(store)?.session.id, let terminal = store.runtimes[id]?.terminal,
           let window = terminal.window, window === NSApp.keyWindow {
            window.makeFirstResponder(terminal)
            NSApp.sendAction(selector, to: terminal, from: sender)
            return
        }
        if !NSApp.sendAction(selector, to: nil, from: sender) { NSSound.beep() }
    }
}
