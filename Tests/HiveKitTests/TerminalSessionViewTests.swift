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
    static func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true, settle: TimeInterval = 0.4) async -> NSBitmapImageRep? {
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

@MainActor
@Suite("Vistas de la sesión, comandos y ajustes", .serialized)
struct TerminalSessionViewTests {
    func check(_ view: some View, size: CGSize, name: String, dark: Bool = true, settle: TimeInterval = 0.4) async {
        let rep = await SessionSnapshot.render(view, size: size, name: name, dark: dark, settle: settle)
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
            await check(SettingsGeneralPane(dataFolder: folder), size: CGSize(width: 540, height: 420), name: "ts-ajustes-general-\(suffix)", dark: dark)
            await check(SettingsTerminalPane(), size: CGSize(width: 540, height: 560), name: "ts-ajustes-terminal-\(suffix)", dark: dark, settle: 0.8)
            await check(SettingsNotificationsPane(), size: CGSize(width: 540, height: 260), name: "ts-ajustes-avisos-\(suffix)", dark: dark)
        }
        await check(SettingsView(dataFolder: folder), size: CGSize(width: 540, height: 480), name: "ts-ajustes")
    }
}
