import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Una ventana con la vista de una sesión y su barra de herramientas, para contar lo que hay en la barra.
@MainActor
private final class ToolbarWindow {
    let window: NSWindow
    let host: NSView
    private let suite = "hive-toolbar-tests-\(UUID().uuidString)"
    private let storage: UserDefaults

    init(_ view: some View, size: CGSize = CGSize(width: 1200, height: 500), dark: Bool) {
        _ = NSApplication.shared
        storage = UserDefaults(suiteName: suite)!
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .defaultAppStorage(storage))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = appearance
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
    }

    var itemCount: Int {
        host.layoutSubtreeIfNeeded()
        return window.toolbar?.items.count ?? 0
    }

    /// Guarda la captura con la barra (con `HIVE_SNAPSHOTS`).
    func capture(_ name: String) -> NSBitmapImageRep? {
        let target: NSView = window.contentView?.superview ?? host
        target.layoutSubtreeIfNeeded()
        guard let rep = Snapshot.bitmap(for: target) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["HIVE_SNAPSHOTS"], let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    func close() {
        window.close()
        storage.removePersistentDomain(forName: suite)
    }
}

@MainActor
@Suite("Barra de la sesión", .serialized)
struct SessionToolbarTests {
    /// Un repo con una sesión de Claude lanzada (con procesos falsos).
    private func storeWithClaude() async throws -> (TestWorld, GitRepo, AppStore, Session) {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.branches[0].sessions.first)
        store.activate(session.id)
        #expect(await waitUntil { store.runtimes[session.id]?.terminal != nil })
        return (world, repo, store, session)
    }

    @Test("Sin sitio, sin remoto y sin uso no quedan cápsulas vacías; cuando aparecen, suman su botón")
    func noEmptyToolbarItems() async throws {
        let (world, repo, store, session) = try await storeWithClaude()
        defer { withExtendedLifetime((world, repo)) {} }
        let empty = UsageMonitor(interval: 3600)
        var base: [Bool: Int] = [:]
        for dark in [true, false] {
            let plain = ToolbarWindow(NavigationStack { SessionDetailView(sessionId: session.id, usage: empty) }.environment(store), dark: dark)
            defer { plain.close() }
            #expect(await waitUntil(timeout: 10) { plain.itemCount > 0 })
            // Le damos tiempo a la lectura del sitio y del remoto (no hay ninguno: no tienen que aparecer).
            try? await Task.sleep(nanoseconds: 800_000_000)
            base[dark] = plain.itemCount
            _ = plain.capture(dark ? "ts-sesion-sin-sitio-ni-remoto" : "ts-sesion-sin-sitio-ni-remoto-claro")
        }

        // Con remoto, sitio (polyscope.json) y uso del contexto aparecen tres botones más.
        repo.sh("git remote add origin git@gitlab.com:dizeg/tienda.git")
        repo.write("polyscope.json", #"{"preview": {"url": "https://{{folder}}.test"}}"#)
        // El uso lo lee el monitor del archivo que deja la barra de estado de Claude.
        try FileManager.default.createDirectory(at: world.paths.usageDir, withIntermediateDirectories: true)
        try #"{"context_window":{"used_percentage":84}}"#
            .write(to: world.paths.usageDir.appendingPathComponent("\(session.id.uuidString).json"), atomically: true, encoding: .utf8)
        let full = UsageMonitor(interval: 3600)
        for dark in [true, false] {
            let rich = ToolbarWindow(NavigationStack { SessionDetailView(sessionId: session.id, usage: full) }.environment(store), dark: dark)
            defer { rich.close() }
            let expected = (base[dark] ?? 0) + 3
            #expect(await waitUntil(timeout: 10) { rich.itemCount >= expected }, "\(rich.itemCount) en lugar de \(expected)")
            _ = rich.capture(dark ? "ts-sesion-con-sitio-y-remoto" : "ts-sesion-con-sitio-y-remoto-claro")
        }
    }

    @Test("Lo leído para otra carpeta no se muestra")
    func loadedIsKeyed() {
        let loaded = SessionLoaded(key: "/a", value: "https://a.test")
        #expect(loaded.value(for: "/a") == "https://a.test")
        #expect(loaded.value(for: "/b") == nil)
        #expect(SessionLoaded<String>(key: "/a", value: nil).value(for: "/a") == nil)
    }
}
