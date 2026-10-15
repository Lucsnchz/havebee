import Foundation
import Testing
@testable import HiveCore

/// EventWatcher de verdad: fuente del sistema de archivos, respaldo por tiempo, stop() y start() repetido.
@Suite("Lector de eventos en vivo")
struct EventWatcherTests {
    /// Espera (sin bloquear) hasta que se cumpla la condición o se acabe el tiempo.
    fileprivate func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Escribe un `.evt` como el script: primero un temporal y después lo renombra.
    fileprivate func emit(_ dir: URL, name: String = UUID().uuidString, event: String = "Stop") throws {
        let tmp = dir.appendingPathComponent("tmp.\(name)")
        try "\(UUID().uuidString)\tclaude\t\(event)\n{}".write(to: tmp, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("tmp.\(name).evt"))
    }

    fileprivate func watcher(_ dir: URL, fallback: TimeInterval, into received: Locked<[HiveEvent]>) -> EventWatcher {
        EventWatcher(directory: dir, queue: DispatchQueue(label: "hive.test.events.\(UUID().uuidString)"), fallbackInterval: fallback) { events in
            received.mutate { $0 += events }
        }
    }

    @Test("start() entrega por el sistema de archivos sin esperar el respaldo")
    func deliversThroughFileSystem() async throws {
        let dir = TempDir("hive-events")
        let received = Locked<[HiveEvent]>([])
        let watcher = watcher(dir.url, fallback: 3600, into: received)
        watcher.start()
        defer { watcher.stop() }
        try emit(dir.url, event: "UserPromptSubmit")
        #expect(await eventually(10) { received.value.count == 1 })
        #expect(received.value.first?.name == "UserPromptSubmit")
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true })
    }

    @Test("El respaldo entrega aunque la carpeta no existiera al arrancar")
    func fallbackWhenMissing() async throws {
        let root = TempDir("hive-events")
        let dir = root.url.appendingPathComponent("events")
        let received = Locked<[HiveEvent]>([])
        let watcher = watcher(dir, fallback: 0.1, into: received)
        watcher.start()
        defer { watcher.stop() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try emit(dir)
        #expect(await eventually(10) { received.value.count == 1 })
        // Después del primer respaldo, la carpeta ya está vigilada y los siguientes llegan igual.
        try emit(dir, event: "Notification")
        #expect(await eventually(10) { received.value.count == 2 })
        #expect(received.value.map(\.name) == ["Stop", "Notification"])
    }

    @Test("start() purga lo viejo y stop() corta las entregas")
    func stopAndPurge() async throws {
        let dir = TempDir("hive-events")
        try emit(dir.url, name: "viejo", event: "Viejo")
        let received = Locked<[HiveEvent]>([])
        let watcher = watcher(dir.url, fallback: 0.1, into: received)
        watcher.start()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        try emit(dir.url, event: "Nuevo")
        #expect(await eventually(10) { received.value.count == 1 })
        watcher.stop()
        try emit(dir.url, name: "despues", event: "Tarde")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(received.value.map(\.name) == ["Nuevo"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["tmp.despues.evt"])
    }

    @Test("start() dos veces no deja una fuente vieja viva ni duplica entregas")
    func startTwice() async throws {
        let dir = TempDir("hive-events")
        let received = Locked<[HiveEvent]>([])
        let watcher = watcher(dir.url, fallback: 0.1, into: received)
        watcher.start()
        watcher.start()
        try emit(dir.url)
        #expect(await eventually(10) { received.value.count == 1 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(received.value.count == 1)
        // Un solo stop() alcanza: si la primera fuente hubiera quedado viva, seguiría leyendo.
        watcher.stop()
        try emit(dir.url, name: "sin-leer")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(received.value.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["tmp.sin-leer.evt"])
    }
}
