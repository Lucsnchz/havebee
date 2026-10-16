import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Proyectos para ver el orden del riel y del árbol: dos fijados (uno con una sesión abierta y
/// otro sin actividad), tres activos (trabajando, con permiso y esperándote), dos apagados y
/// «Terminales». Sin git: el orden y los estados no lo necesitan.
@MainActor
private final class RielDemo {
    let world = TestWorld()
    let folders = TempDir("hive-riel")
    let preferences = SnapshotDefaults()
    let store: AppStore
    var defaults: UserDefaults { preferences.defaults }
    private(set) var ids: [String: UUID] = [:]

    init() throws {
        let now = world.now
        let lastWeek = now.addingTimeInterval(-6 * 86_400)
        let folders = self.folders
        let logo = try Self.writeLogo(in: folders)
        func project(_ name: String, color: TintColor, icon: ProjectIcon? = nil, used: Date?, kind: SessionKind = .claude,
                     pinned: Bool = false) -> Project {
            let sessions = used.map { [Session(name: kind.defaultName + " 1", kind: kind, createdAt: $0)] } ?? []
            return Project(name: name, path: folders.subdir(name).path, branches: [Branch(name: "main", mode: .main, sessions: sessions)],
                           color: color, icon: icon ?? .initials, pinned: pinned)
        }
        let projects = [
            project("ecommerce", color: .blue, used: now),
            project("landing", color: .pink, used: lastWeek),
            project("dizeg", color: .purple, used: now, kind: .codex, pinned: true),
            project("bevo", color: .teal, icon: .image(logo), used: now, kind: .codex),
            project("legacy-api", color: .gray, icon: .symbol("server.rack"), used: lastWeek),
            project("notas", color: .amber, icon: .emoji("📝"), used: lastWeek, pinned: true),
            project("tienda", color: .green, used: now, kind: .gemini),
        ]
        for p in projects { ids[p.name] = p.id }
        try StateStore(file: world.paths.stateFile).save(HiveState(projects: projects))
        store = world.makeStore()
        func session(_ name: String) -> UUID? { store.project(ids[name]!)?.activeSessions.first?.id }
        // Estados: trabajando, necesita permiso, te espera y una abierta sin nada que mostrar.
        store.runtimes[session("ecommerce")!]?.status = .working
        store.runtimes[session("bevo")!]?.status = .attention
        store.runtimes[session("tienda")!]?.status = .waiting
        store.runtimes[session("tienda")!]?.unseen = true
        store.runtimes[session("dizeg")!]?.status = .idle
        store.select(nil)
    }

    /// Un logo cuadrado y simple (para ver el fondo de color detrás de una imagen).
    static func writeLogo(in dir: TempDir) throws -> String {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.10, green: 0.45, blue: 0.42, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 10, dy: 10)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 24, dy: 24)).fill()
            return true
        }
        let url = dir.url.appendingPathComponent("logo.png")
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url.path
    }
}

@MainActor
@Suite("Riel y árbol: orden y estados", .serialized)
struct RielViewTests {
    func check(_ view: some View, size: CGSize, name: String, defaults: UserDefaults) async {
        let reps = await Snapshot.render(view, size: size, name: name, defaults: defaults, settle: 0.6)
        #expect(reps.count == 2, "No se pudo dibujar \(name)")
        for rep in reps {
            #expect(Snapshot.distinctColors(rep) > 3, "\(name) parece vacía")
        }
    }

    @Test("El riel y el árbol muestran el mismo orden: fijados, activos, apagados y «Terminales»")
    func sameOrder() async throws {
        let demo = try RielDemo()
        #expect(demo.store.visibleProjects.map(\.project.name)
            == ["dizeg", "notas", "ecommerce", "bevo", "tienda", "landing", "legacy-api", "Terminales"])
        #expect(demo.store.visibleProjects.filter { !$0.isActive }.map(\.project.name) == ["notas", "landing", "legacy-api", "Terminales"])
        await check(CompactLayout().environment(demo.store).environment(\.hiveNow, demo.world.now),
                    size: CGSize(width: 980, height: 760), name: "riel-01-compacta", defaults: demo.defaults)
        await check(SidebarView().environment(demo.store), size: CGSize(width: 300, height: 760), name: "riel-02-arbol",
                    defaults: demo.defaults)
    }

    @Test("El Resumen del proyecto: aro de permiso lleno y el «!» del globito")
    func projectHeader() async throws {
        let demo = try RielDemo()
        let bevo = try #require(demo.store.visibleProjects.first { $0.project.name == "bevo" })
        await check(ProjectTile(project: bevo.project, size: 56, activity: demo.store.activity(of: bevo.project), showsBadge: true)
                        .padding(20).environment(demo.store),
                    size: CGSize(width: 120, height: 110), name: "riel-03-permiso", defaults: demo.defaults)
    }
}
