import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Dibuja las vistas de navegación (buscador y vista compacta) fuera de pantalla, en oscuro y en
/// claro. Con `HIVE_SNAPSHOTS=<carpeta>` guarda cada captura en PNG para revisarla.
@MainActor
private enum NavSnapshot {
    static func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool, settle: TimeInterval = 0.5) async -> NSBitmapImageRep? {
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
        guard let rep = Snapshot.bitmap(for: host) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["HIVE_SNAPSHOTS"], let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "oscuro" : "claro").png"))
        }
        window.close()
        return rep
    }

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

/// Dos repos con ramas, sesiones en distintos estados y una archivada con historial.
@MainActor
private final class NavDemo {
    let world = TestWorld()
    let ecommerce = GitRepo(name: "ecommerce")
    let bevo = GitRepo(name: "bevo")
    let store: AppStore
    var project: Project { store.repoProjects[0] }
    var claude: Session!
    var codex: Session!
    var archived: Session!

    init() async throws {
        store = world.makeStore()
        await store.addProject(at: ecommerce.path)
        await store.addProject(at: bevo.path)
        let id = project.id
        _ = await store.createBranch(NewBranchRequest(projectId: id, name: "feature/checkout-con-validacion-de-stock",
                                                      isNew: true, mode: .worktree))
        let main = project.branches[0].id
        store.requestNewSession(branchId: main, kind: .claude)
        store.requestNewSession(branchId: main, kind: .codex)
        store.requestNewSession(branchId: main, kind: .claude)
        store.requestNewSession(branchId: project.branches[1].id, kind: .gemini)
        store.requestNewSession(branchId: project.branches[1].id, kind: .shell)
        claude = project.branches[0].sessions[0]
        codex = project.branches[0].sessions[1]
        archived = project.branches[0].sessions[2]
        store.saveCommand(projectId: id, commandId: nil, name: "Servidor", command: "php artisan serve")
        store.select(nil)
        for session in [claude!, codex!, archived!] { store.activate(session.id) }
        store.handle([
            HiveEvent(sessionId: claude.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Agregá validación de stock"]),
            HiveEvent(sessionId: claude.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "Listo, los tests pasan."]),
            HiveEvent(sessionId: codex.id, source: "claude", name: "Notification",
                      payload: ["notification_type": "permission_prompt", "message": "Permiso para correr migraciones"]),
            HiveEvent(sessionId: archived.id, source: "claude", name: "UserPromptSubmit", payload: ["prompt": "Revisá el checkout viejo"]),
            HiveEvent(sessionId: archived.id, source: "claude", name: "Stop", payload: ["last_assistant_message": "El checkout viejo usaba la API v1; ya no hace falta."]),
        ])
        store.archive(archived.id)
        store.select(.session(codex.id))
    }
}

@MainActor
@Suite("Vistas de navegación", .serialized)
struct NavigationViewTests {
    func check(_ view: some View, size: CGSize, name: String) async {
        for dark in [true, false] {
            let rep = await NavSnapshot.render(view, size: size, name: name, dark: dark)
            #expect(rep != nil, "No se pudo dibujar \(name)")
            if let rep { #expect(NavSnapshot.distinctColors(rep) > 3, "\(name) parece vacía") }
        }
    }

    @Test("Buscador: recientes, búsqueda con archivadas, acciones con «>» e historial de una archivada")
    func switcher() async throws {
        let demo = try await NavDemo()
        await check(QuickSwitcher().environment(demo.store), size: CGSize(width: 600, height: 520), name: "nav-01-buscador")
        await check(QuickSwitcher(query: "claude").environment(demo.store), size: CGSize(width: 600, height: 520), name: "nav-02-buscador-busqueda")
        await check(QuickSwitcher(query: ">nueva claude").environment(demo.store), size: CGSize(width: 600, height: 520), name: "nav-03-buscador-acciones")
        await check(QuickSwitcher(archivedId: demo.archived.id).environment(demo.store), size: CGSize(width: 600, height: 520),
                    name: "nav-04-buscador-archivada")
    }

    @Test("Vista compacta: Inicio en el riel, pestañas con la rama y el estado")
    func compact() async throws {
        let demo = try await NavDemo()
        await check(CompactLayout().environment(demo.store), size: CGSize(width: 1100, height: 420), name: "nav-05-compacta")
        demo.store.select(.project(demo.project.id))
        await check(CompactLayout().environment(demo.store), size: CGSize(width: 1100, height: 420), name: "nav-06-compacta-resumen")
    }
}
