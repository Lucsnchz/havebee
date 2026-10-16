import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Dibuja una vista en una ventana fuera de pantalla y, con `HIVE_SNAPSHOTS=<carpeta>`, guarda la
/// captura en PNG. (La terminal y el material del sidebar no salen fuera de pantalla.)
@MainActor
private enum SessionSnapshot {
    static func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true, settle: TimeInterval = 0.4,
                                withToolbar: Bool = false) async -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = appearance
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        host.layoutSubtreeIfNeeded()
        // Con la barra de herramientas: se captura el marco de la ventana entero.
        let target: NSView = withToolbar ? (window.contentView?.superview ?? host) : host
        target.layoutSubtreeIfNeeded()
        guard let rep = Snapshot.bitmap(for: target) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["HIVE_SNAPSHOTS"], let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        window.close()
        return rep
    }

    /// Cuántos colores distintos hay en una grilla de puntos (una imagen vacía tiene uno).
    static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        for x in stride(from: 0, to: rep.pixelsWide, by: max(rep.pixelsWide / 40, 1)) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: max(rep.pixelsHigh / 40, 1)) {
                if let c = rep.colorAt(x: x, y: y) {
                    colors.insert(String(format: "%.2f-%.2f-%.2f", c.redComponent, c.greenComponent, c.blueComponent))
                }
            }
        }
        return colors.count
    }
}


/// Un repo con una rama, sesiones de Claude, Gemini (sin instalar) y Terminal, y un comando corriendo.
@MainActor
private final class SessionDemo {
    let world = TestWorld()
    let repo = GitRepo(name: "ecommerce")
    let store: AppStore
    var project: Project { store.repoProjects[0] }
    var branch: Branch { project.branches[0] }
    var claude: Session { branch.sessions[0] }
    var gemini: Session { branch.sessions[1] }

    init() async throws {
        world.processes.installed.remove("gemini")
        store = world.makeStore()
        repo.write("package.json", #"{"scripts": {"dev": "vite"}}"#)
        repo.commit("Base")
        repo.write("app/Models/Order.php", "<?php\n")
        repo.write("resources/views/home.blade.php", "<div></div>\n")
        await store.addProject(at: repo.path)
        let branchId = project.branches[0].id
        store.requestNewSession(branchId: branchId, kind: .claude)
        store.requestNewSession(branchId: branchId, kind: .gemini)
        store.saveCommand(projectId: project.id, commandId: nil, name: "Servidor", command: "php artisan serve")
        store.saveCommand(projectId: project.id, commandId: nil, name: "Vite", command: "npm run dev")
        store.activate(claude.id)
        store.activate(gemini.id)
        store.select(.session(claude.id))
        store.run(project.commands[0].id, projectId: project.id, branchId: branchId)
        store.run(project.commands[1].id, projectId: project.id, branchId: branchId)
        await store.refreshGitNow()
        store.dockExpanded = false
    }
}

@MainActor
@Suite("Vistas de la sesión, comandos y ajustes", .serialized)
struct TerminalSessionViewTests {
    /// Dibuja con un UserDefaults propio para los @AppStorage (nunca el estándar).
    func check(_ view: some View, size: CGSize, name: String, dark: Bool = true, settle: TimeInterval = 0.4, withToolbar: Bool = false,
               defaults: [String: Any] = [:]) async {
        let suite = "hive-session-views-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        for (key, value) in defaults { storage.set(value, forKey: key) }
        let rep = await SessionSnapshot.render(view.defaultAppStorage(storage), size: size, name: name, dark: dark, settle: settle,
                                               withToolbar: withToolbar)
        #expect(rep != nil, "No se pudo dibujar \(name)")
        if let rep {
            #expect(SessionSnapshot.distinctColors(rep) > 3, "\(name) parece vacía")
        }
    }

    @Test("Ajustes: General, Terminal y Avisos, en oscuro y en claro")
    func settingsPanes() async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        for dark in [true, false] {
            let suffix = dark ? "oscuro" : "claro"
            await check(SettingsGeneralPane(dataFolder: folder), size: CGSize(width: 540, height: 540), name: "ts-ajustes-general-\(suffix)", dark: dark)
            await check(SettingsTerminalPane(), size: CGSize(width: 540, height: 560), name: "ts-ajustes-terminal-\(suffix)", dark: dark, settle: 0.8)
            await check(SettingsNotificationsPane(), size: CGSize(width: 540, height: 260), name: "ts-ajustes-avisos-\(suffix)", dark: dark)
        }
        await check(SettingsView(dataFolder: folder), size: CGSize(width: 540, height: 600), name: "ts-ajustes")
    }

    @Test("Sesión: barra de estado con la rama, los cambios y los comandos; nada encima de la terminal")
    func sessionWithStatusBar() async throws {
        let demo = try await SessionDemo()
        await check(NavigationStack { SessionDetailView(sessionId: demo.claude.id) }.environment(demo.store),
                    size: CGSize(width: 1100, height: 640), name: "ts-sesion", settle: 0.8, withToolbar: true)
        await check(NavigationStack { SessionDetailView(sessionId: demo.claude.id) }.environment(demo.store),
                    size: CGSize(width: 1300, height: 640), name: "ts-sesion-cambios", settle: 0.8, withToolbar: true,
                    defaults: ["sessionSidePanel": "changes"])
        await check(NavigationStack { SessionDetailView(sessionId: demo.claude.id) }.environment(demo.store),
                    size: CGSize(width: 1100, height: 640), name: "ts-sesion-claro", dark: false, settle: 0.8, withToolbar: true)
        await check(SessionStatusBar(project: demo.project, branch: demo.branch).environment(demo.store),
                    size: CGSize(width: 700, height: 25), name: "ts-barra-estado")
        #expect(SessionStatusBar.changesLabel(0) == "Sin cambios")
        #expect(SessionStatusBar.changesLabel(1) == "1 cambio")
        #expect(SessionStatusBar.changesLabel(3) == "3 cambios")
    }

    @Test("Un agente que no está instalado: «No encuentro» con el comando de instalación")
    func missingAgent() async throws {
        let demo = try await SessionDemo()
        #expect(demo.store.runtimes[demo.gemini.id]?.status == .exited(nil))
        await check(NavigationStack { SessionDetailView(sessionId: demo.gemini.id) }.environment(demo.store),
                    size: CGSize(width: 1000, height: 500), name: "ts-sesion-sin-agente", settle: 0.8)
    }

    @Test("«No encuentro» solo si el agente no arrancó y no está en el PATH")
    func missingAgentRule() {
        let nowhere: (String) -> String? = { _ in nil }
        let found: (String) -> String? = { "/fake/bin/\($0)" }
        #expect(MissingAgent.isMissing(kind: .gemini, exitCode: nil, processStarted: false, resolve: nowhere))
        #expect(!MissingAgent.isMissing(kind: .gemini, exitCode: nil, processStarted: false, resolve: found))
        // Salió con un código (por ejemplo /quit): existía, aunque el PATH guardado sea viejo.
        #expect(!MissingAgent.isMissing(kind: .codex, exitCode: 0, processStarted: true, resolve: nowhere))
        #expect(!MissingAgent.isMissing(kind: .claude, exitCode: 1, processStarted: true, resolve: nowhere))
        // Detener (o un cierre forzado) termina por una señal y llega sin código: también existía.
        #expect(!MissingAgent.isMissing(kind: .codex, exitCode: nil, processStarted: true, resolve: nowhere))
        // Una terminal común nunca «falta».
        #expect(!MissingAgent.isMissing(kind: .shell, exitCode: nil, processStarted: false, resolve: nowhere))
    }

    @Test("Una terminal sabe si llegó a lanzar su proceso")
    func terminalStartedFlag() async {
        _ = NSApplication.shared
        let dir = TempDir("hive-started")
        let terminal = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), scrollback: 100)
        #expect(!terminal.hasStartedProcess)
        // /usr/bin/true termina enseguida: no queda nada vivo.
        terminal.startProcess(executable: "/usr/bin/true", args: [], environment: [], currentDirectory: dir.path)
        #expect(terminal.hasStartedProcess)
        #expect(await waitUntil(timeout: 10) { !terminal.isProcessRunning })
    }

    @Test("Comandos: el panel de salida, la esquinita y el editor")
    func commandViews() async throws {
        let demo = try await SessionDemo()
        let run = try #require(demo.store.commandRuns.first)
        await check(CommandRunPanel(run: run).environment(demo.store), size: CGSize(width: 560, height: 340), name: "ts-panel-comando")
        demo.store.showRun(run.id)
        await check(ZStack(alignment: .bottomTrailing) { Color.black; CommandsDock() }.environment(demo.store),
                    size: CGSize(width: 900, height: 500), name: "ts-esquinita")
        let command = try #require(demo.project.commands.first)
        await check(CommandEditorSheet(target: CommandEditorTarget(projectId: demo.project.id, commandId: command.id)).environment(demo.store),
                    size: CGSize(width: 440, height: 240), name: "ts-editor-comando")
        await check(CommandsSection(project: demo.project, showsAddButton: false).padding().environment(demo.store),
                    size: CGSize(width: 700, height: 200), name: "ts-comandos-sin-agregar")
    }
}
