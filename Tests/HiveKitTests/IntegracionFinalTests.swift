import AppKit
import Foundation
import HiveCore
import SwiftTerm
import SwiftUI
import Testing
@testable import HiveKit

/// Lo que se terminó de cablear después de juntar todos los paquetes (I6 a I9 y pendientes).
@MainActor
@Suite("Integración final", .serialized)
struct IntegracionFinalTests {
    /// Dibuja en oscuro y en claro y devuelve cuántos colores distintos tiene cada captura.
    private func colors(_ view: some View, size: CGSize, name: String) async -> [Int] {
        let defaults = SnapshotDefaults()
        let reps = await Snapshot.render(view, size: size, name: name, defaults: defaults.defaults)
        #expect(reps.count == 2, "No se pudo dibujar \(name)")
        return reps.map(Snapshot.distinctColors)
    }

    @Test("I7: en el Resumen, Comandos y MCP no repiten el «Agregar» del título")
    func singleAddButtons() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        defer { withExtendedLifetime(repo) {} }
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        // Sin comandos ni sugerencias (el repo no tiene package.json): sin su botón, la lista no dibuja nada.
        let hidden = await colors(CommandsSection(project: project, showsAddButton: false).environment(store),
                                  size: CGSize(width: 520, height: 60), name: "i7-comandos-sin-agregar")
        #expect(hidden.allSatisfy { $0 == 1 }, "Sin «Agregar comando» no debería verse nada: \(hidden)")
        let shown = await colors(CommandsSection(project: project).environment(store),
                                 size: CGSize(width: 520, height: 60), name: "i7-comandos-con-agregar")
        #expect(shown.allSatisfy { $0 > 1 })

        // Con un comando y un MCP, el Resumen entero se dibuja con las filas como tarjetas.
        repo.write(".mcp.json", #"{"mcpServers": {"docs": {"command": "npx", "args": ["docs-mcp"]}}}"#)
        store.saveCommand(projectId: project.id, commandId: nil, name: "Servidor", command: "php artisan serve")
        let summary = await colors(NavigationStack { ProjectDetailView(projectId: project.id) }.environment(store),
                                   size: CGSize(width: 900, height: 760), name: "i7-resumen")
        #expect(summary.allSatisfy { $0 > 3 })
    }

    /// Un repo con una sesión de Claude que ya habló (el historial queda guardado).
    private func storeWithHistory() async throws -> (TestWorld, GitRepo, AppStore, Project, Session) {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.branches[0].sessions.first)
        store.activate(session.id)
        store.handle([
            HiveEvent(sessionId: session.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Corré la migración de pedidos"]),
            HiveEvent(sessionId: session.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "Listo, la migración pasó sin errores."]),
        ])
        store.select(nil)
        store.setExpanded(project.id, false)
        return (world, repo, store, project, session)
    }

    @Test("I9: «?» en ⌘K encuentra lo que hablaste y abre la sesión en esa entrada")
    func historyFromSwitcher() async throws {
        let (world, repo, store, project, session) = try await storeWithHistory()
        defer { withExtendedLifetime((world, repo)) {} }
        let query = try #require(SwitcherIndex.historyQuery("?migracion"))
        let hits = store.history.search(query, sessionIds: SwitcherIndex.historySessionIds(store.projects), limit: QuickSwitcher.historyLimit)
        let items = SwitcherIndex.historyItems(hits, query: query, in: store.projects)
        #expect(items.count == 2)
        let hit = try #require(hits.first)

        // Abrir: selecciona la sesión, despliega el árbol, pasa el panel a «Historial» y pide el salto.
        let jumps = HistoryJumpRequest()
        let defaults = SnapshotDefaults()
        #expect(HiveNavigator.openHistoryEntry(store, session: session.id, entry: hit.entryId, query: query,
                                               jumps: jumps, defaults: defaults.defaults))
        #expect(store.selection == .session(session.id))
        #expect(store.isExpanded(project.id))
        #expect(defaults.defaults.string(forKey: "sessionSidePanel") == "history")
        #expect(jumps.pending == .init(sessionId: session.id, entryId: hit.entryId, query: query))

        // Una archivada no se abre: queda pedido el salto y el buscador muestra su historial.
        store.archive(session.id)
        store.select(nil)
        let archivedJumps = HistoryJumpRequest()
        #expect(!HiveNavigator.openHistoryEntry(store, session: session.id, entry: hit.entryId, query: query,
                                                jumps: archivedJumps, defaults: defaults.defaults))
        #expect(store.selection == nil)
        #expect(archivedJumps.pending?.entryId == hit.entryId)
    }

    @Test("I9: el buscador con «?» dibuja los mensajes encontrados y la ayuda")
    func historySwitcherRender() async throws {
        let (world, repo, store, _, _) = try await storeWithHistory()
        defer { withExtendedLifetime((world, repo)) {} }
        let found = await colors(QuickSwitcher(query: "?migración").environment(store), size: CGSize(width: 600, height: 520),
                                 name: "i9-buscador-historial")
        #expect(found.allSatisfy { $0 > 3 })
        let hint = await colors(QuickSwitcher(query: "?").environment(store), size: CGSize(width: 600, height: 260),
                                name: "i9-buscador-historial-ayuda")
        #expect(hint.allSatisfy { $0 > 3 })
    }

    @Test("I8: con Swift 6, la paleta le sigue avisando a la terminal si es clara u oscura (modo 2031)")
    func paletteScheme() {
        #expect(TerminalPalette.dark.colorScheme == .dark)
        #expect(TerminalPalette.light.colorScheme == .light)
        #expect(TerminalPalette.dark.isDark && !TerminalPalette.light.isDark)
    }

    @Test("I8: la caché de imágenes de los proyectos recuerda las rutas que no se pueden leer")
    func imageCache() {
        let dir = TempDir()
        let missing = dir.url.appendingPathComponent("no-existe.png").path
        #expect(ImageCache.image(at: missing) == nil)
        let broken = dir.write("roto.png", "no es una imagen").path
        #expect(ImageCache.image(at: broken) == nil)
        ImageCache.forget(broken)
        #expect(ImageCache.image(at: broken) == nil)
    }

    @Test("Si falta el agente, la terminal dice que toques «Reintentar», como el botón de abajo")
    func missingAgentText() async throws {
        let world = TestWorld()
        world.processes.installed = []
        let repo = GitRepo(name: "tienda")
        defer { withExtendedLifetime(repo) {} }
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .codex)
        let session = try #require(store.project(project.id)?.branches[0].sessions.first)
        store.activate(session.id)
        #expect(await waitUntil { store.runtimes[session.id]?.terminal != nil })
        let text = store.runtimes[session.id]?.terminal?.fullText() ?? ""
        #expect(text.contains("No encontré `codex`"))
        #expect(text.contains("«Reintentar»"))
        #expect(!text.contains("Reanudar"))
    }

    @Test("La terminal de un comando usa la letra elegida, un punto más chica, y lo conserva al cambiarla")
    func commandTerminalFont() async throws {
        let suite = SnapshotDefaults()
        suite.defaults.set("Menlo", forKey: "terminalFontName")
        suite.defaults.set(15.0, forKey: "terminalFontSize")
        let terminal = AppStore.makeCommandTerminal(defaults: suite.defaults)
        #expect(terminal.font.familyName == "Menlo")
        #expect(terminal.font.pointSize == 14)
        suite.defaults.set(18.0, forKey: "terminalFontSize")
        terminal.reapplyPreferences()
        #expect(terminal.font.pointSize == 17)
    }

    @Test("Los comandos corren con el SDK de Android a mano (ANDROID_HOME y adb en el PATH)")
    func commandEnvironmentHasAndroidSDK() async throws {
        let world = TestWorld()
        let sdk = world.home.appendingPathComponent("Library/Android/sdk/platform-tools")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let repo = GitRepo(name: "app-android")
        defer { withExtendedLifetime(repo) {} }
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.saveCommand(projectId: project.id, commandId: nil, name: "Logcat", command: "adb logcat")
        let command = try #require(store.project(project.id)?.commands.first)
        store.run(command.id, projectId: project.id)
        let launch = try #require(world.processes.launches.last)
        #expect(launch.args.last == "adb logcat")
        #expect(launch.environment["ANDROID_HOME"] == world.home.appendingPathComponent("Library/Android/sdk").path)
        #expect(launch.environment["PATH"]?.split(separator: ":").contains(Substring(sdk.path)) == true)
    }

    @Test("Limpiar la salida de un comando no le manda Ctrl+L al programa")
    func clearCommandOutput() {
        let suite = SnapshotDefaults()
        let terminal = AppStore.makeCommandTerminal(defaults: suite.defaults)
        var sent: [UInt8] = []
        terminal.onProcessInput = { sent.append(contentsOf: $0) }
        terminal.receive(Array("VITE v5 ready\r\n".utf8)[...])
        #expect(terminal.validateUserInterfaceItem(NSMenuItem(title: "Limpiar", action: #selector(HiveTerminalView.clearTerminal(_:)),
                                                              keyEquivalent: "")))
        terminal.clearTerminal(nil)
        #expect(!terminal.fullText().contains("VITE"))
        #expect(sent.isEmpty)
    }

    @Test("Si otro contenedor se llevó la terminal, mostrarla de nuevo la trae de vuelta")
    func terminalHostReclaims() {
        let first = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let second = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let terminal = NSView(frame: .zero)
        let other = NSView(frame: .zero)
        first.show(terminal)
        #expect(terminal.superview === first)
        // El popover del chip muestra la misma terminal del comando: se la lleva.
        second.show(terminal)
        #expect(terminal.superview === second)
        // La esquinita se vuelve a dibujar con la misma terminal: tiene que volver a tenerla.
        first.show(terminal)
        #expect(terminal.superview === first)
        // Cambiar de terminal en un contenedor no le saca la suya a otro.
        second.show(other)
        #expect(terminal.superview === first)
        #expect(other.superview === second)
        first.show(nil)
        #expect(terminal.superview == nil)
    }

    @Test("Las sugerencias de comandos se leen en segundo plano y no repiten los que ya están")
    func commandSuggestionsOffMain() async throws {
        let dir = TempDir()
        dir.write("package.json", #"{"scripts": {"dev": "vite", "build": "vite build"}}"#)
        let all = await CommandsSection.loadSuggestions(path: dir.path, existing: [])
        #expect(all.map(\.command) == ["npm run dev", "npm run build"])
        let rest = await CommandsSection.loadSuggestions(path: dir.path, existing: [ProjectCommand(name: "Dev", command: "npm run dev")])
        #expect(rest.map(\.command) == ["npm run build"])

        // Y la sección las muestra como chips (sin «Agregar comando» la fila es solo de sugeridos).
        let world = TestWorld()
        let store = world.makeStore()
        let project = Project(name: "web", path: dir.path)
        let drawn = await colors(CommandsSection(project: project, showsAddButton: false).environment(store),
                                 size: CGSize(width: 520, height: 40), name: "comandos-sugeridos")
        #expect(drawn.allSatisfy { $0 > 1 })
    }

    @Test("Los eventos de los agentes se leen en una cola propia y se procesan en orden")
    func eventsOffMain() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        defer { withExtendedLifetime(repo) {} }
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.allSessions.first)
        store.activate(session.id)
        store.select(nil)
        store.start()
        defer { store.shutdown() }
        #expect(store.watcher?.queueLabel == "hive.events")
        let dir = world.paths.eventsDir
        let prompt = "\(session.id.uuidString)\tclaude\tUserPromptSubmit\n{\"prompt\": \"Revisá los tests\"}"
        let stop = "\(session.id.uuidString)\tclaude\tStop\n{\"last_assistant_message\": \"Pasan todos.\"}"
        let first = dir.appendingPathComponent("1.evt")
        let second = dir.appendingPathComponent("2.evt")
        try prompt.write(to: first, atomically: true, encoding: .utf8)
        try stop.write(to: second, atomically: true, encoding: .utf8)
        // Primero el pedido (trabajando) y después el Stop: queda esperándote, con el nombre del pedido.
        #expect(await waitUntil { store.runtimes[session.id]?.status == .waiting })
        #expect(store.sessionContext(session.id)?.session.name == "Revisá los tests")
    }

    @Test("Abrir una sesión desde el Inicio despliega su proyecto y su rama en el árbol")
    func homeCardReveals() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        defer { withExtendedLifetime(repo) {} }
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.allSessions.first)
        store.select(nil)
        store.setExpanded(project.id, false)
        store.setExpanded(project.branches[0].id, false)
        SessionCard.open(session.id, in: store)
        #expect(store.selection == .session(session.id))
        #expect(store.isExpanded(project.id))
        #expect(store.isExpanded(project.branches[0].id))
    }

    @Test("Mientras se borra un worktree, sus sesiones no se vuelven a lanzar")
    func noRelaunchWhileRemovingWorktree() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        defer { withExtendedLifetime(repo) {} }
        repo.write("polyscope.json", #"{"scripts": {"archive": "herd unsecure tienda"}}"#)
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        #expect(await store.createBranch(NewBranchRequest(projectId: project.id, name: "feature-x", isNew: true, mode: .worktree,
                                                          copyIgnored: false, setupCommand: nil)) == nil)
        let branch = try #require(store.project(project.id)?.branches.first { $0.name == "feature-x" })
        store.requestNewSession(branchId: branch.id, kind: .claude)
        let session = try #require(store.project(project.id)?.branches.first { $0.id == branch.id }?.sessions.first)
        store.activate(session.id)
        #expect(store.runtimes[session.id]?.isRunning == true)

        let removal = Task { await store.performRemove(.branch(branch.id), deleteWorktree: true) }
        // El script de cierre corre: la sesión ya se cortó y la carpeta todavía existe.
        #expect(await waitUntil { store.commandRuns.contains { $0.isScript && $0.name == "Cerrar feature-x" } })
        #expect(store.removingBranches.contains(branch.id))
        store.activate(session.id)
        store.relaunch(session.id)
        #expect(store.runtimes[session.id]?.isRunning != true)
        let run = try #require(store.commandRuns.first { $0.isScript })
        store.commandExited(run.id, terminal: try #require(run.terminal), code: 0)
        #expect(await removal.value)
        #expect(store.removingBranches.isEmpty)
        #expect(store.sessionContext(session.id) == nil)
    }

    @Test("El store recuerda qué herramienta pidió permiso hasta que la respondés")
    func pendingPermissionInStore() async throws {
        let (world, repo, store, _, session) = try await storeWithHistory()
        defer { withExtendedLifetime((world, repo)) {} }
        func send(_ name: String, _ payload: JSONValue) {
            store.handle([HiveEvent(sessionId: session.id, source: "claude", name: name, payload: payload)])
        }
        let rt = try #require(store.runtimes[session.id])
        send("UserPromptSubmit", ["prompt": "Migrá la base"])
        send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "php artisan migrate"]])
        #expect(rt.status == .attention)
        #expect(rt.notice?.contains("php artisan migrate") == true)
        send("PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/e/a.php"]])
        #expect(rt.status == .attention)
        #expect(rt.notice != nil)
        // Aprobás con Enter: trabaja y se olvida el pedido.
        rt.terminal?.onUserInput?(Array("\r".utf8)[...])
        #expect(rt.status == .working)
        #expect(rt.pendingPermission == nil)
        send("PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/e/a.php"]])
        #expect(rt.status == .working)
    }
}
