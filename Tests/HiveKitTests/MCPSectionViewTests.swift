import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Dibuja una vista fuera de pantalla (en oscuro) y, con `HIVE_SNAPSHOTS`, guarda la captura.
@MainActor
private enum MCPViewRender {
    static func render<V: View>(_ view: V, size: CGSize, name: String) async -> NSBitmapImageRep? {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 500_000_000) // deja correr las tareas de carga (.task)
        let rep = capture(host, name: name)
        window.close()
        return rep
    }

    /// La captura de una vista ya dibujada; con `HIVE_SNAPSHOTS` también la guarda en PNG.
    static func capture(_ host: NSView, name: String) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["HIVE_SNAPSHOTS"], let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    static func isDrawn(_ rep: NSBitmapImageRep?) -> Bool {
        guard let rep else { return false }
        var colors = Set<String>()
        for x in stride(from: 0, to: rep.pixelsWide, by: max(rep.pixelsWide / 40, 1)) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: max(rep.pixelsHigh / 40, 1)) {
                if let c = rep.colorAt(x: x, y: y) { colors.insert(String(format: "%.2f-%.2f-%.2f", c.redComponent, c.greenComponent, c.blueComponent)) }
            }
        }
        return colors.count > 3
    }
}

/// Un UserDefaults propio para el `@AppStorage` de los sugeridos: otros procesos de test comparten el estándar.
private final class MCPTestDefaults: @unchecked Sendable {
    let name = "hive-mcp-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }

    deinit { defaults.removePersistentDomain(forName: name) }
}

@MainActor
@Suite("Vistas de MCP", .serialized)
struct MCPSectionViewTests {
    private let storage = MCPTestDefaults()

    func section(_ project: Project, store: AppStore, showsAddButton: Bool = true) -> some View {
        MCPSection(project: project, showsAddButton: showsAddButton)
            .environment(store)
            .defaultAppStorage(storage.defaults)
            .padding(20)
    }

    @Test("Con un .mcp.json roto muestra el aviso y no toca el archivo")
    func invalidFile() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = TempDir()
        repo.write("artisan")
        let broken = #"{"mcpServers": {"a": {"command": "x"} "b": {"command": "y"}}}"#
        repo.write(".mcp.json", broken)
        let project = Project(name: "roto", path: repo.path)
        let rep = await MCPViewRender.render(section(project, store: store), size: CGSize(width: 760, height: 260), name: "mcp-invalido")
        #expect(MCPViewRender.isDrawn(rep))
        #expect(repo.read(".mcp.json") == broken)
    }

    @Test("Sin MCP: los sugeridos se ven abiertos, como chips")
    func suggestionsOpen() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = TempDir()
        repo.write("artisan")
        repo.write("package.json", #"{"dependencies": {"next": "15"}}"#)
        repo.write("gradlew")
        let project = Project(name: "nuevo", path: repo.path)
        let rep = await MCPViewRender.render(section(project, store: store), size: CGSize(width: 520, height: 300), name: "mcp-sugeridos")
        #expect(MCPViewRender.isDrawn(rep))
    }

    @Test("Con MCP y sin el botón de agregar (para el título de la sección)")
    func withServersNoAddButton() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = TempDir()
        try MCPConfig.upsert(MCPServer(name: "docs", config: ["type": "sse", "url": "https://docs.ejemplo.com/sse"]), dir: repo.path)
        try MCPConfig.upsert(MCPServer(name: "windows", config: ["command": "C:/php/php.exe", "args": ["x"]]), dir: repo.path)
        let project = Project(name: "con-mcp", path: repo.path)
        let rep = await MCPViewRender.render(section(project, store: store, showsAddButton: false),
                                             size: CGSize(width: 760, height: 280), name: "mcp-lista")
        #expect(MCPViewRender.isDrawn(rep))
    }

    @Test("Editor de un MCP remoto")
    func remoteEditor() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = GitRepo(name: "ecommerce")
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        try MCPConfig.upsert(MCPServer(name: "docs", config: ["type": "sse", "url": "https://docs.ejemplo.com/sse"]), dir: project.path)
        let rep = await MCPViewRender.render(MCPEditorSheet(target: MCPEditorTarget(projectId: project.id, serverName: "docs")).environment(store),
                                             size: CGSize(width: 480, height: 330), name: "mcp-editor-remoto")
        #expect(MCPViewRender.isDrawn(rep))
        // Abrirlo no cambia nada: sigue siendo sse.
        #expect(MCPConfig.load(dir: project.path).first { $0.name == "docs" }?.config["type"] == "sse")
    }

    @Test("El entorno muestra lo que cargó y se edita sin comillas tipográficas ni rayas")
    func environmentEditorIsPlain() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = GitRepo(name: "node")
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        let env = "NODE_OPTIONS=--max-old-space-size=4096"
        try MCPConfig.upsert(MCPServer(name: "node", config: ["command": "node", "env": ["NODE_OPTIONS": "--max-old-space-size=4096"]]),
                             dir: project.path)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: MCPEditorSheet(target: MCPEditorTarget(projectId: project.id, serverName: "node"))
            .environment(store)
            .frame(width: 480, height: 360)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }

        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        // La carga del servidor es asíncrona: esperamos a que el editor muestre el entorno.
        let loaded = await waitUntil(timeout: 10) {
            host.layoutSubtreeIfNeeded()
            return textViews(host).contains { $0.string == env }
        }
        #expect(loaded)
        let editor = try #require(textViews(host).first { $0.string == env })
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(!editor.isRichText)
        #expect(MCPViewRender.isDrawn(MCPViewRender.capture(host, name: "mcp-editor-entorno")))
    }

    // MARK: - Lo que lee la sección (fuera del hilo principal)

    @Test("Con el archivo roto: el error, sin sugeridos (agregar fallaría) y el archivo existe")
    func scanBrokenFile() {
        let repo = TempDir()
        repo.write("artisan")
        repo.write(".mcp.json", #"{"mcpServers": {"a": {"command": "x"} "b": {"command": "y"}}}"#)
        let data = MCPSectionData.scan(projectPath: repo.path, home: TempDir().url)
        #expect(data.servers == .failure(.invalidJSON(MCPConfig.url(in: repo.path).path)))
        #expect(data.suggestions.isEmpty)
        #expect(data.fileExists)
        #expect(data.brokenPaths.isEmpty)
    }

    @Test("Con servidores: las rutas rotas por nombre y los sugeridos sin los que ya están")
    func scanServers() throws {
        let repo = TempDir()
        repo.write("artisan")
        try MCPConfig.upsert(MCPServer(name: "laravel-boost", config: ["command": "php", "args": ["artisan", "boost:mcp"]]), dir: repo.path)
        try MCPConfig.upsert(MCPServer(name: "windows", config: ["command": "C:/php/php.exe"]), dir: repo.path)
        let data = MCPSectionData.scan(projectPath: repo.path, home: TempDir().url)
        #expect((try? data.servers.get())?.map(\.name) == ["laravel-boost", "windows"])
        #expect(data.brokenPaths == ["windows": "C:/php/php.exe"])
        #expect(data.fileExists)
        #expect(!data.suggestions.map(\.name).contains("laravel-boost"))
        #expect(data.suggestions.map(\.name).contains("context7"))
    }

    @Test("Sugeridos: abiertos sin MCP, cerrados con MCP, y no se cierran después de agregar uno desde ahí")
    func suggestionsExpandedRule() {
        #expect(MCPSectionData.suggestionsExpanded(saved: "", hasServers: false, addedFromSuggestions: false))
        #expect(!MCPSectionData.suggestionsExpanded(saved: "", hasServers: true, addedFromSuggestions: false))
        #expect(MCPSectionData.suggestionsExpanded(saved: "", hasServers: true, addedFromSuggestions: true))
        // Lo que eligió el usuario manda.
        #expect(MCPSectionData.suggestionsExpanded(saved: "open", hasServers: true, addedFromSuggestions: false))
        #expect(!MCPSectionData.suggestionsExpanded(saved: "closed", hasServers: false, addedFromSuggestions: true))
    }

    @Test("Sin .mcp.json: sin servidores, sin error y con sugeridos")
    func scanMissingFile() {
        let repo = TempDir()
        let data = MCPSectionData.scan(projectPath: repo.path, home: TempDir().url)
        #expect(data.servers == .success([]))
        #expect(!data.fileExists)
        #expect(data.suggestions.map(\.name) == ["context7"])
    }
}
