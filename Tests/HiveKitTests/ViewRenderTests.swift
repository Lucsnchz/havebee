import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Dibuja vistas reales en una ventana fuera de pantalla, en oscuro y en claro: confirma que se
/// arman sin romperse y que dibujan algo. Con `HIVE_SNAPSHOTS=<carpeta>` además guarda cada captura
/// en PNG para revisarla («nombre.png» en oscuro y «nombre-claro.png» en claro).
@MainActor
enum Snapshot {
    /// «Ahora» fijo para las fechas relativas (2 de octubre de 2026): las capturas no cambian día a día.
    static let now = Date(timeIntervalSince1970: 1_790_942_400)

    /// Devuelve las dos capturas: oscuro y claro. La misma vista se dibuja primero en oscuro y
    /// después se pasa a claro (así las tareas de carga corren una sola vez).
    static func render<V: View>(_ view: V, size: CGSize, name: String, defaults: UserDefaults,
                                settle: TimeInterval = 0.4) async -> [NSBitmapImageRep] {
        _ = NSApplication.shared
        func root(_ scheme: ColorScheme) -> AnyView {
            // Fondo opaco: en una ventana fuera de pantalla no se dibuja el de la ventana.
            AnyView(view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
                .environment(\.hiveNow, now)
                .defaultAppStorage(defaults))
        }
        let host = NSHostingView(rootView: root(.dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        var reps: [NSBitmapImageRep] = []
        for (appearance, scheme, suffix) in [(NSAppearance.Name.darkAqua, ColorScheme.dark, ""), (.aqua, .light, "-claro")] {
            window.appearance = NSAppearance(named: appearance)
            host.appearance = NSAppearance(named: appearance)
            host.rootView = root(scheme)
            host.layoutSubtreeIfNeeded()
            // Dejamos correr las tareas de carga de las vistas (.task) la primera vez.
            let wait = reps.isEmpty ? settle : 0.15
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            host.layoutSubtreeIfNeeded()
            guard let rep = bitmap(for: host) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["HIVE_SNAPSHOTS"], let png = rep.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png"))
            }
            reps.append(rep)
        }
        window.close()
        return reps
    }

    /// Un lienzo a 2x, sea cual sea la pantalla: con un monitor común (o con la pantalla apagada) la
    /// ventana fuera de pantalla queda a 1x, las líneas finas y el texto chico casi no aparecen en la
    /// grilla de `distinctColors` y las capturas para revisar salen borrosas.
    static func bitmap(for view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
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

    /// Brillo promedio (0 negro, 1 blanco), para confirmar que la captura es oscura o clara.
    static func averageBrightness(_ rep: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: max(rep.pixelsWide / 30, 1)) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: max(rep.pixelsHigh / 30, 1)) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    total += Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
                    count += 1
                }
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }
}

/// Preferencias aisladas para las vistas (@AppStorage): nunca UserDefaults.standard, que comparten
/// todos los procesos de test de la Mac. El nombre de la suite es una ruta absoluta dentro de una
/// carpeta temporal, así el plist queda ahí y se borra con ella: con un nombre común iría a
/// ~/Library/Preferences, y removePersistentDomain no borra ese archivo.
@MainActor
final class SnapshotDefaults {
    private let dir = TempDir("hive-snapshots")
    let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = dir.url.appendingPathComponent("preferencias").path
        defaults = UserDefaults(suiteName: suiteName)!
    }

    /// Dónde guarda el plist (para el test que confirma que no va a ~/Library/Preferences).
    var plistPath: String { suiteName + ".plist" }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
@Suite("Preferencias de las capturas")
struct SnapshotDefaultsTests {
    @Test("Se guardan en una carpeta temporal y no en ~/Library/Preferences")
    func staysInTempDir() async throws {
        let preferences = SnapshotDefaults()
        preferences.defaults.set("tree", forKey: "layout")
        preferences.defaults.synchronize()
        #expect(preferences.suiteName.hasPrefix(TempDir.realPath(NSTemporaryDirectory())))
        #expect(preferences.defaults.string(forKey: "layout") == "tree")
        // Otra instancia con el mismo nombre (como hace @AppStorage) ve lo mismo.
        #expect(UserDefaults(suiteName: preferences.suiteName)?.string(forKey: "layout") == "tree")
        let plist = preferences.plistPath
        #expect(await waitUntil { FileManager.default.fileExists(atPath: plist) })
    }
}

/// Un store con datos realistas: dos repos, ramas, sesiones en distintos estados, comandos e historial.
@MainActor
final class DemoData {
    let world = TestWorld()
    let ecommerce = GitRepo(name: "ecommerce")
    let bevo = GitRepo(name: "bevo")
    let store: AppStore
    let preferences = SnapshotDefaults()
    var defaults: UserDefaults { preferences.defaults }
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
        // Sirve tanto si el lanzamiento es sincrónico como si es asincrónico.
        let claudeId = claude.id, codexId = codex.id
        _ = await waitUntil { [store] in store.runtimes[claudeId]?.terminal != nil && store.runtimes[codexId]?.terminal != nil }
        store.handle([
            HiveEvent(sessionId: claude.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Agregá validación de stock al checkout"]),
            HiveEvent(sessionId: claude.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "Listo: agregué la validación y los tests pasan."]),
            HiveEvent(sessionId: claude.id, source: "claude", name: "SessionStart", payload: ["source": "clear", "session_id": "x"]),
            HiveEvent(sessionId: codex.id, source: "claude", name: "Notification", payload: ["notification_type": "permission_prompt", "message": "Permiso para correr migraciones"]),
        ])
        await store.refreshGitNow()
    }
}

/// Arma DemoData una sola vez para toda la suite de vistas (y lo suelta al terminar).
private struct SharedDemoTrait: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let demo = try await DemoData()
        try await SharedDemo.$current.withValue(demo) {
            try await function()
        }
    }
}

private enum SharedDemo {
    @TaskLocal static var current: DemoData?
}

@MainActor
@Suite("Vistas", .serialized, SharedDemoTrait())
struct ViewRenderTests {
    private func demo() throws -> DemoData {
        try #require(SharedDemo.current, "Falta el DemoData de la suite")
    }

    func check(_ view: some View, size: CGSize, name: String, defaults: UserDefaults, settle: TimeInterval = 0.4) async {
        let reps = await Snapshot.render(view, size: size, name: name, defaults: defaults, settle: settle)
        #expect(reps.count == 2, "No se pudo dibujar \(name)")
        for (index, rep) in reps.enumerated() {
            let variant = index == 0 ? "oscuro" : "claro"
            #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
            #expect(Snapshot.distinctColors(rep) > 3, "\(name) (\(variant)) parece vacía")
        }
    }

    @Test("Ventana principal: vista de árbol con una sesión abierta")
    func treeLayout() async throws {
        let demo = try demo()
        demo.defaults.set("tree", forKey: "layout")
        demo.store.select(.session(demo.claude.id))
        await check(ContentView().environment(demo.store), size: CGSize(width: 1280, height: 800), name: "01-arbol-sesion",
                    defaults: demo.defaults, settle: 0.8)
    }

    @Test("Ventana principal: vista compacta")
    func compactLayout() async throws {
        let demo = try demo()
        demo.store.select(.session(demo.codex.id))
        await check(CompactLayout().environment(demo.store), size: CGSize(width: 1280, height: 800), name: "02-compacta",
                    defaults: demo.defaults, settle: 0.8)
    }

    @Test("Resumen del proyecto")
    func projectDetail() async throws {
        let demo = try demo()
        await check(NavigationStack { ProjectDetailView(projectId: demo.project.id) }.environment(demo.store),
                    size: CGSize(width: 1000, height: 1100), name: "03-resumen-proyecto", defaults: demo.defaults)
    }

    @Test("Vista de una rama")
    func branchDetail() async throws {
        let demo = try demo()
        await check(NavigationStack { BranchDetailView(branchId: demo.project.branches[0].id) }.environment(demo.store),
                    size: CGSize(width: 1000, height: 1100), name: "04-rama", defaults: demo.defaults)
    }

    @Test("«Terminales»")
    func scratch() async throws {
        let demo = try demo()
        let scratch = try #require(demo.store.scratchProject)
        if scratch.branches[0].activeSessions.isEmpty {
            demo.store.requestNewSession(branchId: scratch.branches[0].id, kind: .shell)
        }
        await check(NavigationStack { BranchDetailView(branchId: scratch.branches[0].id) }.environment(demo.store),
                    size: CGSize(width: 1000, height: 700), name: "05-terminales", defaults: demo.defaults)
    }

    @Test("Sesión con el panel de historial y con el de cambios")
    func sessionPanels() async throws {
        let demo = try demo()
        demo.defaults.set("history", forKey: "sessionSidePanel")
        await check(NavigationStack { SessionDetailView(sessionId: demo.claude.id) }.environment(demo.store),
                    size: CGSize(width: 1200, height: 700), name: "06-sesion-historial", defaults: demo.defaults, settle: 0.8)
        demo.defaults.set("changes", forKey: "sessionSidePanel")
        await check(NavigationStack { SessionDetailView(sessionId: demo.claude.id) }.environment(demo.store),
                    size: CGSize(width: 1200, height: 700), name: "07-sesion-cambios", defaults: demo.defaults, settle: 0.8)
        demo.defaults.set("", forKey: "sessionSidePanel")
    }

    @Test("Hojas: nueva rama, personalizar, comando, MCP y ajustes")
    func sheets() async throws {
        let demo = try demo()
        let id = demo.project.id
        let defaults = demo.defaults
        await check(NewBranchSheet(projectId: id).environment(demo.store), size: CGSize(width: 500, height: 620), name: "08-nueva-rama",
                    defaults: defaults)
        await check(CustomizeProjectSheet(projectId: id).environment(demo.store), size: CGSize(width: 470, height: 520), name: "09-personalizar",
                    defaults: defaults)
        await check(CommandEditorSheet(target: CommandEditorTarget(projectId: id, commandId: nil)).environment(demo.store),
                    size: CGSize(width: 440, height: 260), name: "10-comando", defaults: defaults)
        await check(MCPEditorSheet(target: MCPEditorTarget(projectId: id, serverName: "laravel-boost")).environment(demo.store),
                    size: CGSize(width: 480, height: 420), name: "11-mcp", defaults: defaults)
        await check(SettingsView(dataFolder: demo.world.paths.root), size: CGSize(width: 520, height: 320), name: "12-ajustes",
                    defaults: defaults)
    }

    @Test("Buscador, diff y esquinita de comandos")
    func overlays() async throws {
        let demo = try demo()
        await check(QuickSwitcher().environment(demo.store), size: CGSize(width: 580, height: 500), name: "13-buscador",
                    defaults: demo.defaults)

        let status = try #require(demo.store.gitStatus(for: demo.project.branches[0], in: demo.project))
        let change = try #require(status.changes.first { $0.path.hasSuffix("Order.php") })
        let target = DiffTarget.make(directory: demo.ecommerce.path, status: status, change: change, staged: false)
        await check(DiffSheet(target: target).environment(demo.store), size: CGSize(width: 1060, height: 680), name: "14-diff",
                    defaults: demo.defaults, settle: 0.8)

        let command = try #require(demo.project.commands.first)
        demo.store.run(command.id, projectId: demo.project.id)
        await check(ZStack(alignment: .bottomTrailing) { Color.black; CommandsDock() }.environment(demo.store),
                    size: CGSize(width: 900, height: 500), name: "15-comandos", defaults: demo.defaults)
        // Que la esquinita no aparezca en las capturas de los otros tests.
        for run in demo.store.commandRuns { demo.store.closeRun(run.id) }
    }

    @Test("Rama sin sesiones con un agente sin instalar, y una sesión trabajando")
    func emptyBranchAndWorking() async throws {
        let defaults = try demo().defaults
        // Un store aparte: así no cambia lo que ven las otras capturas.
        let world = TestWorld()
        world.processes.installed = ["claude", "codex"]
        let repo = GitRepo(name: "bevo")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        let branchId = project.branches[0].id
        await AgentAvailability.shared(for: store).refresh().value
        #expect(!AgentAvailability.shared(for: store).isInstalled(.gemini))
        await check(NavigationStack { BranchDetailView(branchId: branchId) }.environment(store),
                    size: CGSize(width: 1000, height: 640), name: "17-rama-vacia", defaults: defaults)

        store.requestNewSession(branchId: branchId, kind: .claude)
        let session = try #require(store.project(project.id)?.branches[0].sessions.first)
        store.activate(session.id)
        #expect(await waitUntil { store.runtimes[session.id]?.terminal != nil })
        world.now = Snapshot.now.addingTimeInterval(-134)
        store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Revisá los tests"])])
        #expect(store.runtimes[session.id]?.status == .working)
        await check(NavigationStack { BranchDetailView(branchId: branchId) }.environment(store),
                    size: CGSize(width: 1000, height: 640), name: "18-rama-trabajando", defaults: defaults)
    }

    @Test("Las capturas en claro son claras y las de oscuro, oscuras")
    func appearances() async throws {
        let demo = try demo()
        let reps = await Snapshot.render(NavigationStack { ProjectDetailView(projectId: demo.project.id) }.environment(demo.store),
                                         size: CGSize(width: 600, height: 400), name: "16-apariencias", defaults: demo.defaults, settle: 0.2)
        try #require(reps.count == 2)
        #expect(Snapshot.averageBrightness(reps[0]) < 0.4)
        #expect(Snapshot.averageBrightness(reps[1]) > 0.6)
    }
}

@MainActor
@Suite("Foco de la terminal")
struct TerminalFocusTests {
    @Test("Toma el foco si nadie lo tiene o lo tenía otra terminal; no se lo saca al sidebar ni a un campo")
    func focusRule() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(TerminalHostView.shouldTakeFocus(from: nil, in: window))
        #expect(TerminalHostView.shouldTakeFocus(from: window, in: window))
        #expect(TerminalHostView.shouldTakeFocus(from: HiveTerminalView(frame: .zero), in: window))
        #expect(!TerminalHostView.shouldTakeFocus(from: NSOutlineView(), in: window))
        #expect(!TerminalHostView.shouldTakeFocus(from: NSTextView(), in: window))
        #expect(!TerminalHostView.shouldTakeFocus(from: NSTextField(), in: window))
    }

    @Test("Con un clic sí lo toma (también desde el sidebar), pero nunca se lo saca a un campo de texto")
    func focusAfterClick() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(TerminalHostView.shouldTakeFocus(from: NSOutlineView(), in: window, afterClick: true))
        #expect(TerminalHostView.shouldTakeFocus(from: window, in: window, afterClick: true))
        #expect(!TerminalHostView.shouldTakeFocus(from: NSTextView(), in: window, afterClick: true))
        #expect(!TerminalHostView.shouldTakeFocus(from: NSTextField(), in: window, afterClick: true))
    }

    @Test("Solo cuenta un clic reciente: ni una tecla ni un clic viejo")
    func recentClick() throws {
        func mouse(_ type: NSEvent.EventType, at time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        #expect(TerminalHostView.isRecentClick(try mouse(.leftMouseDown, at: 100), now: 100.3))
        #expect(TerminalHostView.isRecentClick(try mouse(.leftMouseUp, at: 100), now: 100.9))
        #expect(!TerminalHostView.isRecentClick(try mouse(.leftMouseUp, at: 100), now: 105))
        #expect(!TerminalHostView.isRecentClick(try mouse(.mouseMoved, at: 100), now: 100.1))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 100, windowNumber: 0,
                                                context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                                isARepeat: false, keyCode: 125))
        #expect(!TerminalHostView.isRecentClick(key, now: 100.1))
        #expect(!TerminalHostView.isRecentClick(nil))
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
