import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Clics de verdad en el riel de la vista compacta, con agentes trabajando: lo que se ve a la
/// derecha (pestañas y terminal) tiene que ser siempre el proyecto que marca el riel.
@MainActor
@Suite("Vista compacta: clics en el riel")
struct RailClickTests {
    func click(_ window: NSWindow, yFromTop: CGFloat) {
        let point = NSPoint(x: 36, y: (window.contentView?.bounds.height ?? 0) - yFromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            if let event { window.sendEvent(event) }
        }
    }

    /// El color del ícono del proyecto en la barra de pestañas, a la derecha del riel.
    func tabBarColor(_ host: NSView) -> [Double]? {
        guard let rep = Snapshot.bitmap(for: host) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Ícono de 18 pt en x 85…103, y 11…29: un punto cerca del borde, fuera de las iniciales.
        guard let c = rep.colorAt(x: 88 * 2, y: 14 * 2)?.usingColorSpace(.deviceRGB) else { return nil }
        return [c.redComponent, c.greenComponent, c.blueComponent]
    }

    func nearest(_ color: [Double], _ table: [String: [Double]]) -> String {
        func distance(_ other: [Double]) -> Double { zip(color, other).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) }
        return table.min { distance($0.value) < distance($1.value) }?.key ?? "?"
    }

    @Test("Las pestañas siguen al proyecto que tocás, y volver a tocarlo redibuja")
    func clicks() async throws {
        let world = TestWorld()
        let repos = [GitRepo(name: "tienda"), GitRepo(name: "plagas"), GitRepo(name: "colmena")]
        let store = world.makeStore()
        for repo in repos { await store.addProject(at: repo.path) }
        var sessions: [UUID] = []
        for project in store.repoProjects {
            store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
            let id = try #require(store.project(project.id)?.branches[0].sessions.last?.id)
            store.activate(id)
            sessions.append(id)
        }
        _ = NSApplication.shared
        let size = CGSize(width: 900, height: 520)
        let host = NSHostingView(rootView: CompactLayout().environment(store).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        // El color de cada proyecto, eligiéndolo directo.
        var colors: [String: [Double]] = [:]
        for (index, project) in store.repoProjects.enumerated() {
            store.select(.session(sessions[index]))
            try await Task.sleep(nanoseconds: 300_000_000)
            colors[project.name] = try #require(tabBarColor(host))
        }

        // Los agentes trabajan mientras tanto: avisos y salida en las terminales.
        var running = true
        let activity = Task { @MainActor in
            var n = 0
            while running {
                n += 1
                for id in sessions {
                    store.handle([HiveEvent(sessionId: id, source: "claude", name: n % 4 == 0 ? "Stop" : "PreToolUse",
                                            payload: ["tool_name": "Bash", "last_assistant_message": "Listo"])])
                    store.runtimes[id]?.terminal?.feed(text: "línea \(n)\r\n")
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        // Los tres proyectos del riel, en su orden: y 93…149, 157…213 y 221…277.
        let rail: [(y: CGFloat, name: String)] = [(121, "tienda"), (185, "plagas"), (249, "colmena")]
        for index in [0, 1, 2, 0, 2, 1] {
            click(window, yFromTop: rail[index].y)
            try await Task.sleep(nanoseconds: 250_000_000)
            #expect(store.currentProjectId.flatMap { store.project($0)?.name } == rail[index].name)
            #expect(nearest(try #require(tabBarColor(host)), colors) == rail[index].name)
        }
        running = false
        _ = await activity.value

        // Tocar otra vez lo que ya está elegido no cambia la selección, pero redibuja.
        let version = store.navigationVersion
        let selection = store.selection
        click(window, yFromTop: 185)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.selection == selection)
        #expect(store.navigationVersion == version + 1, "antes \(version), después \(store.navigationVersion)")
    }

    @Test("Quien redibuja en medio del cambio de selección termina viendo la nueva")
    func rereadDuringChange() async throws {
        let world = TestWorld()
        let repos = [GitRepo(name: "tienda"), GitRepo(name: "plagas")]
        let store = world.makeStore()
        for repo in repos { await store.addProject(at: repo.path) }
        let ids = store.repoProjects.map(\.id)
        store.select(.project(ids[0]))

        let reader = SelectionReader(store: store)
        reader.read()
        store.select(.project(ids[1]))
        #expect(reader.seen.first == .project(ids[0]))
        #expect(reader.seen.last == .project(ids[1]), "leyó \(reader.seen)")
    }
}

/// Hace lo que SwiftUI cuando el aviso de un cambio le llega en medio de una actualización (la
/// acción de un botón): redibuja ahí mismo, antes de que se guarde el valor nuevo, y se vuelve a
/// suscribir. Así las pestañas y la terminal se quedaban en el proyecto anterior.
@MainActor
private final class SelectionReader {
    let store: AppStore
    var seen: [SidebarItem?] = []

    init(store: AppStore) { self.store = store }

    func read() {
        seen.append(withObservationTracking { store.selection } onChange: { [self] in
            MainActor.assumeIsolated { read() }
        })
    }
}
