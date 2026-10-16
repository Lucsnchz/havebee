import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

@MainActor
@Suite("Menús y atajos")
struct HiveCommandsTests {
    typealias Shortcut = HiveCommands.Shortcut

    @Test("No hay dos ítems con el mismo atajo")
    func noDuplicates() {
        var seen: [String: String] = [:]
        for shortcut in Shortcut.all {
            #expect(seen[shortcut.signature] == nil, "\(shortcut.name) repite \(shortcut) de \(seen[shortcut.signature] ?? "")")
            seen[shortcut.signature] = shortcut.name
        }
        #expect(Set(Shortcut.all).count == Shortcut.all.count)
    }

    @Test("Ningún atajo pisa uno de macOS")
    func noSystemConflicts() {
        let system = Set(Shortcut.system)
        for shortcut in Shortcut.all {
            #expect(!system.contains(shortcut), "\(shortcut.name) (\(shortcut)) choca con uno del sistema")
        }
    }

    @Test("Los atajos se muestran como en los menús de macOS")
    func display() {
        #expect(Shortcut.newSession.description == "⌘T")
        #expect(Shortcut.newBranch.description == "⇧⌘N")
        #expect(Shortcut.nextProject.description == "⌥⌘↓")
        #expect(Shortcut.history.description == "⌥⌘1")
        #expect(Shortcut.tabs.map(\.description) == (1...9).map { "⌘\($0)" })
        #expect(Shortcut.projects.map(\.description) == (1...9).map { "⌃⌘\($0)" })
        #expect(Shortcut.home.description == "⇧⌘H")
        #expect(Shortcut.actualSize.description == "⌘0")
    }

    @Test("El riel de la vista compacta dice cuántas sesiones te esperan")
    func railAccessibility() {
        let project = Project(name: "ecommerce", path: "/e")
        #expect(RailItem.accessibilityText(project: project, activity: Activity()) == "ecommerce")
        #expect(RailItem.accessibilityText(project: project, activity: Activity(pending: 1)) == "ecommerce, una sesión te espera")
        #expect(RailItem.accessibilityText(project: project, activity: Activity(pending: 1, attention: 1))
            == "ecommerce, 2 sesiones te esperan")
        #expect(HiveCommands.Shortcut.tab(0)?.description == "⌘1")
        #expect(HiveCommands.Shortcut.tab(9) == nil)
        #expect(HiveCommands.Shortcut.project(8)?.description == "⌃⌘9")
        #expect(HiveCommands.Shortcut.project(-1) == nil)
    }

    @Test("Soltar en el riel: solo carpetas que existen, aunque la URL no termine en barra")
    func droppedFolders() throws {
        let dir = TempDir("hive-drop")
        let repo = dir.subdir("ecommerce").path
        let file = dir.write("notas.txt", "hola").path
        let urls = [
            try #require(URL(string: "file://\(repo)")), // sin la barra final de las carpetas
            URL(fileURLWithPath: file),
            URL(fileURLWithPath: dir.url.appendingPathComponent("no-existe").path),
            try #require(URL(string: "https://gitlab.com/equipo/ecommerce")),
        ]
        #expect(!urls[0].hasDirectoryPath)
        #expect(CompactLayout.droppedFolders(urls) == [repo])
        #expect(CompactLayout.droppedFolders([URL(fileURLWithPath: repo, isDirectory: true)]) == [repo])
    }

    @Test("⌘W archiva solo en la ventana principal, sin hojas y con una sesión abierta")
    func closeDecision() {
        let id = UUID()
        #expect(HiveNavigator.closeDecision(selection: .session(id), keyWindowIsMain: true, sheetOpen: false) == .archive(id))
        #expect(HiveNavigator.closeDecision(selection: .session(id), keyWindowIsMain: false, sheetOpen: false) == .closeWindow)
        #expect(HiveNavigator.closeDecision(selection: .session(id), keyWindowIsMain: true, sheetOpen: true) == .closeWindow)
        #expect(HiveNavigator.closeDecision(selection: .project(id), keyWindowIsMain: true, sheetOpen: false) == .closeWindow)
        #expect(HiveNavigator.closeDecision(selection: nil, keyWindowIsMain: true, sheetOpen: false) == .closeWindow)
    }

    @Test("⌘. detiene la sesión solo en la ventana principal; en una hoja u otra ventana cancela")
    func stopDecision() {
        let id = UUID()
        #expect(HiveNavigator.stopDecision(selection: .session(id), keyWindowIsMain: true, sheetOpen: false) == .stop(id))
        // En el buscador (⌘K) o en Ajustes, ⌘. no corta la sesión que quedó detrás.
        #expect(HiveNavigator.stopDecision(selection: .session(id), keyWindowIsMain: false, sheetOpen: false) == .cancel)
        #expect(HiveNavigator.stopDecision(selection: .session(id), keyWindowIsMain: true, sheetOpen: true) == .cancel)
        #expect(HiveNavigator.stopDecision(selection: .project(id), keyWindowIsMain: true, sheetOpen: false) == .cancel)
    }

    @Test("⌘F/⌘G con el foco en la barra de búsqueda de la terminal la usan sin mover el foco")
    func terminalContainingFocus() throws {
        let terminal = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 150, height: 22))
        bar.addSubview(field)
        terminal.addSubview(bar)
        // Otro campo de la ventana, fuera de la terminal (como el buscador del historial).
        let outside = NSSearchField(frame: NSRect(x: 420, y: 0, width: 150, height: 22))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        content.addSubview(terminal)
        content.addSubview(outside)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }

        #expect(HiveNavigator.terminal(containing: terminal) === terminal)
        #expect(HiveNavigator.terminal(containing: field) === terminal)
        // Mientras escribís en el campo, el foco lo tiene el editor de campo de la ventana.
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(HiveNavigator.terminal(containing: editor) === terminal)
        #expect(window.makeFirstResponder(outside))
        #expect(HiveNavigator.terminal(containing: window.firstResponder) == nil)
        #expect(HiveNavigator.terminal(containing: NSTextView()) == nil)
        #expect(HiveNavigator.terminal(containing: nil) == nil)
    }

    @Test("Historial solo en los agentes y Cambios fuera de «Terminales», como en la barra de la sesión")
    func sidePanels() {
        let claude = Session(name: "Claude 1", kind: .claude, createdAt: Date())
        let shell = Session(name: "Terminal 1", kind: .shell, createdAt: Date())
        let main = Branch(name: "main", mode: .main, sessions: [claude, shell])
        let repo = Project(name: "ecommerce", path: "/e", branches: [main])
        let scratch = Project.scratch(home: "/h")
        #expect(HiveNavigator.sidePanels(nil) == (false, false))
        #expect(HiveNavigator.sidePanels((repo, main, claude)) == (true, true))
        #expect(HiveNavigator.sidePanels((repo, main, shell)) == (false, true))
        #expect(HiveNavigator.sidePanels((scratch, scratch.branches[0], claude)) == (true, false))
    }

    @Test("Tamaño de letra: un punto por vez, entre 9 y 28")
    func fontSize() {
        typealias FontSize = HiveCommands.FontSize
        #expect(FontSize.stepped(13, by: 1) == 14)
        #expect(FontSize.stepped(28, by: 1) == 28)
        #expect(FontSize.stepped(9, by: -1) == 9)
        #expect(FontSize.stepped(12.6, by: 1) == 14)
        let suite = "hive-font-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FontSize.current(defaults) == 13)
        FontSize.change(by: 1, defaults: defaults)
        #expect(defaults.double(forKey: FontSize.key) == 14)
        defaults.set(40, forKey: FontSize.key)
        #expect(FontSize.current(defaults) == 28)
        FontSize.change(by: -1, defaults: defaults)
        #expect(defaults.double(forKey: FontSize.key) == 27)
        FontSize.reset(defaults: defaults)
        #expect(FontSize.current(defaults) == 13)
    }

    @Test("⌘= agranda el texto; los demás atajos siguen de largo")
    func keyDown() {
        let suite = "hive-keys-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
        }
        #expect(HiveCommands.handleKeyDown(key("=", .command), defaults: defaults))
        #expect(defaults.double(forKey: HiveCommands.FontSize.key) == 14)
        #expect(!HiveCommands.handleKeyDown(key("k", .command), defaults: defaults))
        #expect(!HiveCommands.handleKeyDown(key("=", []), defaults: defaults))
        #expect(!HiveCommands.handleKeyDown(key("=", [.command, .option]), defaults: defaults))
        #expect(defaults.double(forKey: HiveCommands.FontSize.key) == 14)
    }
}

@MainActor
@Suite("Navegar con el teclado")
struct HiveNavigatorTests {
    /// Un repo con dos ramas y sesiones, y «Terminales» con una terminal.
    @MainActor
    final class NavWorld {
        let world = TestWorld()
        let repo = GitRepo(name: "ecommerce")
        let store: AppStore
        var project: Project { store.repoProjects[0] }
        var scratch: Project { store.scratchProject! }

        init() async throws {
            store = world.makeStore()
            await store.addProject(at: repo.path)
            _ = await store.createBranch(NewBranchRequest(projectId: project.id, name: "seguridad", isNew: true, mode: .worktree))
            store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
            store.requestNewSession(branchId: project.branches[0].id, kind: .codex)
            store.requestNewSession(branchId: project.branches[1].id, kind: .shell)
            store.requestNewSession(branchId: scratch.branches[0].id, kind: .shell)
            store.select(nil)
        }

        var tabs: [UUID] { SessionNavigation.orderedSessions(in: project).map(\.id) }
    }

    @Test("⌘T: mismo agente que la sesión abierta, en su rama; si no hay sesión, Claude en la rama por defecto")
    func newSession() async throws {
        let w = try await NavWorld()
        #expect(HiveNavigator.newSessionTarget(w.store) == nil) // en el Inicio no hay proyecto
        let codex = w.tabs[1]
        w.store.select(.session(codex))
        let target = try #require(HiveNavigator.newSessionTarget(w.store))
        #expect(target.kind == .codex && target.branchId == w.project.branches[0].id)
        HiveNavigator.newSession(w.store)
        let created = try #require(HiveNavigator.selectedSession(w.store))
        #expect(created.session.kind == .codex && created.session.name == "Codex 2")
        #expect(created.branch.id == w.project.branches[0].id)

        w.store.select(.branch(w.project.branches[1].id))
        let onBranch = try #require(HiveNavigator.newSessionTarget(w.store))
        #expect(onBranch.kind == .claude && onBranch.branchId == w.project.branches[1].id)
        HiveNavigator.newSession(w.store, kind: .gemini)
        #expect(HiveNavigator.selectedSession(w.store)?.session.kind == .gemini)
    }

    @Test("⌘1…⌘9 y ⇧⌘] / ⇧⌘[ recorren las pestañas y despliegan el árbol")
    func tabs() async throws {
        let w = try await NavWorld()
        w.store.select(.project(w.project.id))
        w.store.setExpanded(w.project.branches[1].id, false)
        HiveNavigator.goToTab(w.store, index: 2)
        #expect(w.store.selection == .session(w.tabs[2]))
        #expect(w.store.isExpanded(w.project.branches[1].id))
        HiveNavigator.goToTab(w.store, index: 8) // no existe: no cambia nada
        #expect(w.store.selection == .session(w.tabs[2]))
        HiveNavigator.goToAdjacentSession(w.store, delta: 1)
        #expect(w.store.selection == .session(w.tabs[0]))
        HiveNavigator.goToAdjacentSession(w.store, delta: -1)
        #expect(w.store.selection == .session(w.tabs[2]))
    }

    @Test("⌃⌘N y ⌥⌘↓ / ⌥⌘↑ cambian de proyecto")
    func projects() async throws {
        let w = try await NavWorld()
        w.store.setExpanded(w.scratch.id, false)
        HiveNavigator.goToProject(w.store, index: 1)
        #expect(w.store.currentProjectId == w.scratch.id)
        #expect(w.store.isExpanded(w.scratch.id))
        HiveNavigator.goToAdjacentProject(w.store, delta: 1)
        #expect(w.store.currentProjectId == w.project.id)
        HiveNavigator.goToAdjacentProject(w.store, delta: -1)
        #expect(w.store.currentProjectId == w.scratch.id)
        HiveNavigator.goToProject(w.store, index: 5) // no existe
        #expect(w.store.currentProjectId == w.scratch.id)
    }

    @Test("⌘J va primero a la que pide permiso y después a la que espera hace más")
    func nextWaiting() async throws {
        let w = try await NavWorld()
        #expect(!HiveNavigator.goToNextWaiting(w.store))
        let (claude, codex, shell) = (w.tabs[0], w.tabs[1], w.tabs[2])
        w.store.runtimes[claude]?.unseen = true
        w.store.runtimes[shell]?.unseen = true
        w.store.runtimes[codex]?.status = .attention
        #expect(HiveNavigator.goToNextWaiting(w.store))
        #expect(w.store.selection == .session(codex))
        // Desde la que pide permiso, a la siguiente que te espera.
        #expect(HiveNavigator.goToNextWaiting(w.store))
        let next = try #require(HiveNavigator.selectedSession(w.store)?.session.id)
        #expect(next == claude || next == shell)
    }
}
