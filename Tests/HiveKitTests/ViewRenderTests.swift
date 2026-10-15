import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Dibuja vistas reales en una ventana fuera de pantalla: confirma que se arman sin romperse y que
/// dibujan algo. Con `HIVE_SNAPSHOTS=<carpeta>` además guarda cada captura en PNG para revisarla.
@MainActor
enum Snapshot {
    @discardableResult
    static func render<V: View>(_ view: V, size: CGSize, name: String, settle: TimeInterval = 0.4) async -> NSBitmapImageRep? {
        _ = NSApplication.shared
        // Fondo opaco: en una ventana fuera de pantalla no se dibuja el de la ventana.
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        // Dejamos correr las tareas de carga de las vistas (.task).
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
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

/// Un store con datos realistas: dos repos, ramas, sesiones en distintos estados, comandos e historial.
@MainActor
final class DemoData {
    let world = TestWorld()
    let ecommerce = GitRepo(name: "ecommerce")
    let bevo = GitRepo(name: "bevo")
    let store: AppStore
    var project: Project { store.repoProjects[0] }
    var claude: Session!
    var codex: Session!

    init() async throws {
        world.settings = AppSettings()
        store = world.makeStore()
        ecommerce.write("app/Models/Order.php", "<?php\n")
        ecommerce.write("package.json", #"{"scripts": {"dev": "vite"}}"#)
        ecommerce.write("artisan", "")
        ecommerce.commit("Base")
        ecommerce.write("app/Models/Order.php", "<?php\n// cambio\n")
        ecommerce.write("resources/views/home.blade.php", "<div></div>\n")
        await store.addProject(at: ecommerce.path)
        await store.addProject(at: bevo.path)
        let id = project.id
        _ = await store.createBranch(NewBranchRequest(projectId: id, name: "SEGURIDAD", isNew: true, mode: .worktree))
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        store.requestNewSession(branchId: project.branches[0].id, kind: .codex)
        store.requestNewSession(branchId: project.branches[0].id, kind: .shell)
        store.requestNewSession(branchId: project.branches[1].id, kind: .gemini)
        claude = project.branches[0].sessions[0]
        codex = project.branches[0].sessions[1]
        store.saveCommand(projectId: id, commandId: nil, name: "Servidor", command: "php artisan serve")
        try? MCPConfig.upsert(MCPServer(name: "laravel-boost", config: ["command": "php", "args": ["artisan", "boost:mcp"]]), dir: ecommerce.path)
        store.select(nil)
        store.activate(claude.id)
        store.activate(codex.id)
        store.handle([
            HiveEvent(sessionId: claude.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Agregá validación de stock al checkout"]),
            HiveEvent(sessionId: claude.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "Listo: agregué la validación y los tests pasan."]),
            HiveEvent(sessionId: claude.id, source: "claude", name: "SessionStart", payload: ["source": "clear", "session_id": "x"]),
            HiveEvent(sessionId: codex.id, source: "claude", name: "Notification", payload: ["notification_type": "permission_prompt", "message": "Permiso para correr migraciones"]),
        ])
        await store.refreshGitNow()
    }
}

@MainActor
@Suite("Vistas", .serialized)
struct ViewRenderTests {
    func check(_ view: some View, size: CGSize, name: String, settle: TimeInterval = 0.4) async {
        let rep = await Snapshot.render(view, size: size, name: name, settle: settle)
        #expect(rep != nil, "No se pudo dibujar \(name)")
        if let rep {
            #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
            #expect(Snapshot.distinctColors(rep) > 3, "\(name) parece vacía")
        }
    }

    @Test("Ventana principal: vista de árbol con una sesión abierta")
    func treeLayout() async throws {
        let demo = try await DemoData()
        UserDefaults.standard.set("tree", forKey: "layout")
        demo.store.select(.session(demo.claude.id))
        await check(ContentView().environment(demo.store), size: CGSize(width: 1280, height: 800), name: "01-arbol-sesion", settle: 0.8)
    }

    @Test("Ventana principal: vista compacta")
    func compactLayout() async throws {
        let demo = try await DemoData()
        demo.store.select(.session(demo.codex.id))
        await check(CompactLayout().environment(demo.store), size: CGSize(width: 1280, height: 800), name: "02-compacta", settle: 0.8)
    }

    @Test("Resumen del proyecto")
    func projectDetail() async throws {
        let demo = try await DemoData()
        await check(NavigationStack { ProjectDetailView(projectId: demo.project.id) }.environment(demo.store),
                    size: CGSize(width: 1000, height: 1100), name: "03-resumen-proyecto")
    }

    @Test("Vista de una rama")
    func branchDetail() async throws {
        let demo = try await DemoData()
        await check(NavigationStack { BranchDetailView(branchId: demo.project.branches[0].id) }.environment(demo.store),
                    size: CGSize(width: 1000, height: 1100), name: "04-rama")
    }

    @Test("«Terminales»")
    func scratch() async throws {
        let demo = try await DemoData()
        let scratch = try #require(demo.store.scratchProject)
        demo.store.requestNewSession(branchId: scratch.branches[0].id, kind: .shell)
        await check(NavigationStack { BranchDetailView(branchId: scratch.branches[0].id) }.environment(demo.store),
                    size: CGSize(width: 1000, height: 700), name: "05-terminales")
    }

    @Test("Sesión con el panel de historial y con el de cambios")
    func sessionPanels() async throws {
        let demo = try await DemoData()
        UserDefaults.standard.set("history", forKey: "sessionSidePanel")
        await check(NavigationStack { SessionDetailView(sessionId: demo.claude.id) }.environment(demo.store),
                    size: CGSize(width: 1200, height: 700), name: "06-sesion-historial", settle: 0.8)
        UserDefaults.standard.set("changes", forKey: "sessionSidePanel")
        await check(NavigationStack { SessionDetailView(sessionId: demo.claude.id) }.environment(demo.store),
                    size: CGSize(width: 1200, height: 700), name: "07-sesion-cambios", settle: 0.8)
        UserDefaults.standard.set("", forKey: "sessionSidePanel")
    }

    @Test("Hojas: nueva rama, personalizar, comando, MCP y ajustes")
    func sheets() async throws {
        let demo = try await DemoData()
        let id = demo.project.id
        await check(NewBranchSheet(projectId: id).environment(demo.store), size: CGSize(width: 500, height: 620), name: "08-nueva-rama")
        await check(CustomizeProjectSheet(projectId: id).environment(demo.store), size: CGSize(width: 470, height: 520), name: "09-personalizar")
        await check(CommandEditorSheet(target: CommandEditorTarget(projectId: id, commandId: nil)).environment(demo.store),
                    size: CGSize(width: 440, height: 260), name: "10-comando")
        await check(MCPEditorSheet(target: MCPEditorTarget(projectId: id, serverName: "laravel-boost")).environment(demo.store),
                    size: CGSize(width: 480, height: 420), name: "11-mcp")
        await check(SettingsView(dataFolder: demo.world.paths.root), size: CGSize(width: 520, height: 320), name: "12-ajustes")
    }

    @Test("Buscador, diff y esquinita de comandos")
    func overlays() async throws {
        let demo = try await DemoData()
        await check(QuickSwitcher().environment(demo.store), size: CGSize(width: 580, height: 500), name: "13-buscador")

        let status = try #require(demo.store.gitStatus(for: demo.project.branches[0], in: demo.project))
        let change = try #require(status.changes.first { $0.path.hasSuffix("Order.php") })
        let target = DiffTarget.make(directory: demo.ecommerce.path, status: status, change: change, staged: false)
        await check(DiffSheet(target: target).environment(demo.store), size: CGSize(width: 1060, height: 680), name: "14-diff", settle: 0.8)

        let command = try #require(demo.project.commands.first)
        demo.store.run(command.id, projectId: demo.project.id)
        await check(ZStack(alignment: .bottomTrailing) { Color.black; CommandsDock() }.environment(demo.store),
                    size: CGSize(width: 900, height: 500), name: "15-comandos")
    }
}

@MainActor
@Suite("Logos")
struct LogoTests {
    @Test("Cada agente tiene su logo original; la terminal usa un símbolo del sistema")
    func logos() throws {
        for kind in [SessionKind.claude, .codex, .gemini] {
            let image = try #require(AgentLogo.image(kind), "Falta el logo de \(kind.label)")
            #expect(image.size == NSSize(width: 128, height: 128))
            #expect(!AgentLogo.menuImage(kind).isTemplate)
        }
        #expect(AgentLogo.image(.shell) == nil)
        #expect(AgentLogo.menuImage(.shell).isTemplate)
    }
}
