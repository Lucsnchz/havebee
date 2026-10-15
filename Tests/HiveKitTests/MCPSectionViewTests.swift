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

@MainActor
@Suite("Vistas de MCP", .serialized)
struct MCPSectionViewTests {
    @Test("Con un .mcp.json roto muestra el aviso y no toca el archivo")
    func invalidFile() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        let repo = TempDir()
        repo.write("artisan")
        let broken = #"{"mcpServers": {"a": {"command": "x"} "b": {"command": "y"}}}"#
        repo.write(".mcp.json", broken)
        let project = Project(name: "roto", path: repo.path)
        let rep = await MCPViewRender.render(MCPSection(project: project).environment(store).padding(20),
                                             size: CGSize(width: 760, height: 260), name: "mcp-invalido")
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
        let rep = await MCPViewRender.render(MCPSection(project: project).environment(store).padding(20),
                                             size: CGSize(width: 520, height: 300), name: "mcp-sugeridos")
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
        let rep = await MCPViewRender.render(MCPSection(project: project, showsAddButton: false).environment(store).padding(20),
                                             size: CGSize(width: 760, height: 280), name: "mcp-lista")
        #expect(MCPViewRender.isDrawn(rep))
    }

    @Test("Editor de un MCP remoto")
    func remoteEditor() async throws {
        let demo = try await DemoData()
        try MCPConfig.upsert(MCPServer(name: "docs", config: ["type": "sse", "url": "https://docs.ejemplo.com/sse"]), dir: demo.project.path)
        let rep = await MCPViewRender.render(MCPEditorSheet(target: MCPEditorTarget(projectId: demo.project.id, serverName: "docs")).environment(demo.store),
                                             size: CGSize(width: 480, height: 330), name: "mcp-editor-remoto")
        #expect(MCPViewRender.isDrawn(rep))
        // Abrirlo no cambia nada: sigue siendo sse.
        #expect(MCPConfig.load(dir: demo.project.path).first { $0.name == "docs" }?.config["type"] == "sse")
    }
}
