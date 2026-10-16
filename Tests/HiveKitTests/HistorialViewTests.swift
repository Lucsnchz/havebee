import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Dibuja una vista fuera de pantalla (en oscuro o en claro) y, con `HIVE_SNAPSHOTS=<carpeta>`,
/// guarda la captura en PNG. Propia de este archivo para no depender de otras suites.
@MainActor
private func ahRender<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true, settle: TimeInterval = 0.8) async -> NSBitmapImageRep? {
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
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    window.close()
    return rep
}

/// Colores distintos en una grilla de puntos (una imagen vacía tiene uno solo).
private func ahDistinctColors(_ rep: NSBitmapImageRep) -> Int {
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

/// Un transcript de Claude chico, con textos intermedios y un bloque de código.
private let ahClaudeTranscript = #"""
{"type":"user","message":{"role":"user","content":"Agregá validación de stock al checkout"},"uuid":"u1","timestamp":"2026-10-14T13:00:00.000Z","sessionId":"conv-1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Voy a revisar `CheckoutController` y los **tests** primero."}]},"uuid":"a1","timestamp":"2026-10-14T13:00:04.000Z","sessionId":"conv-1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]},"uuid":"a2","timestamp":"2026-10-14T13:00:05.000Z","sessionId":"conv-1"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"..."}]},"uuid":"u2","timestamp":"2026-10-14T13:00:06.000Z","sessionId":"conv-1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## Listo\n\nAgregué la **validación** de stock:\n\n- Si no alcanza, tira `OutOfStock`.\n- Los 12 tests pasan.\n\n```php\nif ($item->stock < $qty) {\n    throw new OutOfStock($item);\n}\n```"}]},"uuid":"a3","timestamp":"2026-10-14T13:02:00.000Z","sessionId":"conv-1"}
"""#

@MainActor
@Suite("Vistas del historial y del uso", .serialized)
struct HistorialViewTests {
    /// Un store con un proyecto, una sesión de Claude con historial completo y una de Codex archivada.
    @MainActor final class Demo {
        let world = TestWorld()
        let repo = TempDir("hive-ah-repo")
        let store: AppStore
        let claude: Session
        let codex: Session
        let defaults: UserDefaults
        let suiteName = "hive-ah-\(UUID().uuidString)"

        init(showEverything: Bool = true) throws {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(showEverything, forKey: "historyShowEverything")
            let now = Date()
            claude = Session(name: "Validar stock", kind: .claude, agentSessionId: "conv-1", lastActivityAt: now)
            codex = Session(name: "Login", kind: .codex, agentSessionId: "019a-thread", lastActivityAt: now, archivedAt: now)
            let project = Project(name: "ecommerce", path: repo.path, branches: [Branch(name: "main", mode: .main, sessions: [claude, codex])])
            try StateStore(file: world.paths.stateFile).save(HiveState(projects: [project]))
            store = world.makeStore()

            // Lo que guardaron los hooks y la copia completa del transcript.
            let history = store.history
            let day = try Date("2026-10-14T13:00:00Z", strategy: .iso8601)
            history.ensureMarkdown(session: claude, place: "ecommerce › main")
            history.append(HistoryEntry(date: day.addingTimeInterval(-86_400), role: .user, text: "¿Cómo se llama la tabla de pedidos?"),
                           sessionId: claude.id, agentName: "Claude Code")
            history.append(HistoryEntry(date: day.addingTimeInterval(-86_390), role: .assistant, text: "Se llama `orders` y tiene **12** columnas."),
                           sessionId: claude.id, agentName: "Claude Code")
            history.append(HistoryEntry(date: day.addingTimeInterval(-60), role: .marker, text: "/clear"), sessionId: claude.id, agentName: "Claude Code")
            history.append(HistoryEntry(date: day.addingTimeInterval(1), role: .user, text: "Agregá validación de stock al checkout"),
                           sessionId: claude.id, agentName: "Claude Code")
            history.append(HistoryEntry(date: day.addingTimeInterval(150), role: .system, text: "<task-notification>El build terminó bien</task-notification>"),
                           sessionId: claude.id, agentName: "Claude Code")
            history.append(HistoryEntry(date: day.addingTimeInterval(200), role: .marker, text: "⚠︎ Se cortó: rate_limit"),
                           sessionId: claude.id, agentName: "Claude Code")
            let transcript = world.dir.write("claude/projects/-code/conv-1.jsonl", ahClaudeTranscript)
            history.archiveTranscript(sessionId: claude.id, agent: .claude, path: transcript.path)
            history.append(HistoryEntry(date: day, role: .user, text: "Arreglá la validación del login"), sessionId: codex.id, agentName: "Codex")
            history.append(HistoryEntry(date: day.addingTimeInterval(30), role: .assistant, text: "Listo: la validación del login ya anda."),
                           sessionId: codex.id, agentName: "Codex")
        }

        deinit { defaults.removePersistentDomain(forName: suiteName) }
    }

    func check(_ view: some View, size: CGSize, name: String, dark: Bool = true, settle: TimeInterval = 0.8) async {
        let rep = await ahRender(view, size: size, name: name, dark: dark, settle: settle)
        #expect(rep != nil, "No se pudo dibujar \(name)")
        if let rep { #expect(ahDistinctColors(rep) > 3, "\(name) parece vacía") }
    }

    @Test("Historial: todo, con Markdown, días y bloques de código")
    func historyEverything() async throws {
        let demo = try Demo()
        let view = HistoryPanel(session: demo.claude).environment(demo.store).defaultAppStorage(demo.defaults)
        await check(view, size: CGSize(width: 420, height: 900), name: "ah-01-historial-todo")
        await check(view, size: CGSize(width: 420, height: 900), name: "ah-02-historial-todo-claro", dark: false)
        // La línea de tiempo tiene los textos intermedios y no repite el pedido.
        let timeline = demo.store.history.fullTimeline(demo.claude.id, agent: .claude)
        #expect(timeline.contains { $0.text.hasPrefix("Voy a revisar") })
        #expect(timeline.filter { $0.text == "Agregá validación de stock al checkout" }.count == 1)
    }

    @Test("Historial: solo respuestas finales y búsqueda")
    func historyFinals() async throws {
        let demo = try Demo(showEverything: false)
        HistoryJumpRequest.shared.pending = nil
        await check(HistoryPanel(session: demo.claude).environment(demo.store).defaultAppStorage(demo.defaults),
                    size: CGSize(width: 420, height: 700), name: "ah-03-historial-finales")
        // Llegar desde la búsqueda global: muestra la búsqueda y salta a la entrada.
        let entry = try #require(demo.store.history.fullTimeline(demo.claude.id, agent: .claude).first { $0.text.hasPrefix("## Listo") })
        HistoryJumpRequest.shared.pending = .init(sessionId: demo.claude.id, entryId: entry.id, query: "validacion")
        await check(HistoryPanel(session: demo.claude).environment(demo.store).defaultAppStorage(demo.defaults),
                    size: CGSize(width: 420, height: 700), name: "ah-04-historial-busqueda", settle: 1.2)
        #expect(HistoryJumpRequest.shared.pending == nil)
        #expect(demo.defaults.bool(forKey: "historyShowEverything")) // pasó a «Todo» porque la entrada es intermedia
    }

    @Test("Historial en el ancho mínimo del panel (260 pt), con una búsqueda")
    func historyNarrow() async throws {
        let demo = try Demo()
        let entry = try #require(demo.store.history.fullTimeline(demo.claude.id, agent: .claude).first { $0.text.hasPrefix("## Listo") })
        HistoryJumpRequest.shared.pending = .init(sessionId: demo.claude.id, entryId: entry.id, query: "validacion")
        await check(HistoryPanel(session: demo.claude).environment(demo.store).defaultAppStorage(demo.defaults),
                    size: CGSize(width: 260, height: 600), name: "ah-10-historial-angosto", settle: 1.2)
        #expect(HistoryJumpRequest.shared.pending == nil)
    }

    @Test("Historial vacío de Gemini con «Copiar el scroll de la terminal»")
    func historyGemini() async throws {
        let demo = try Demo()
        let gemini = Session(name: "Gemini 1", kind: .gemini)
        await check(HistoryPanel(session: gemini).environment(demo.store).defaultAppStorage(demo.defaults),
                    size: CGSize(width: 360, height: 300), name: "ah-05-historial-gemini")
    }

    @Test("Buscar en todas las sesiones, también en las archivadas")
    func globalSearch() async throws {
        let demo = try Demo()
        let view = HistorySearchView(initialQuery: "validacion").environment(demo.store).defaultAppStorage(demo.defaults)
        await check(view, size: CGSize(width: 640, height: 540), name: "ah-06-buscar-todas", settle: 1.2)
        await check(view, size: CGSize(width: 640, height: 540), name: "ah-07-buscar-todas-claro", dark: false, settle: 1.2)
        let hits = demo.store.history.search("validacion", sessionIds: [demo.claude.id, demo.codex.id])
        #expect(Set(hits.map(\.sessionId)) == [demo.claude.id, demo.codex.id])
        // Leyendo una archivada desde la búsqueda: el panel no ofrece abrir otra búsqueda encima.
        await check(HistoryPanel(session: demo.codex, showsGlobalSearch: false).environment(demo.store).defaultAppStorage(demo.defaults),
                    size: CGSize(width: 420, height: 400), name: "ah-11-historial-archivada")
    }

    @Test("Uso: el monitor lee Claude y Codex y las vistas lo muestran")
    func usage() async throws {
        let demo = try Demo()
        let codexActive = Session(name: "Codex 2", kind: .codex, agentSessionId: "019a-activo")
        demo.store.requestNewSession(branchId: try #require(demo.store.projects.first { !$0.isScratch }).branches[0].id, kind: .claude)
        let resets = Int(Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970)
        let soon = Int(Date().addingTimeInterval(2 * 3600).timeIntervalSince1970)
        try FileManager.default.createDirectory(at: demo.world.paths.usageDir, withIntermediateDirectories: true)
        try #"{"context_window":{"used_percentage":84.2},"rate_limits":{"five_hour":{"used_percentage":23,"resets_at":\#(soon)},"seven_day":{"used_percentage":41,"resets_at":\#(resets)}}}"#
            .write(to: demo.world.paths.usageDir.appendingPathComponent("\(demo.claude.id.uuidString).json"), atomically: true, encoding: .utf8)
        demo.world.dir.write("codex/sessions/2026/10/14/rollout-2026-10-14T10-00-00-019a-activo.jsonl", """
        {"timestamp":"2026-10-14T10:00:00Z","type":"session_meta","payload":{"id":"019a-activo","cwd":"/x","source":"cli"}}
        {"timestamp":"2026-10-14T10:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":51680},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":80.0,"window_minutes":10080,"resets_at":\(resets)},"secondary":null}}}
        """)
        // La sesión de Codex activa se agrega al proyecto guardado.
        var state = HiveState(projects: demo.store.projects)
        state.projects[0].branches[0].sessions.append(codexActive)
        try StateStore(file: demo.world.paths.stateFile).save(state)
        let store = demo.world.makeStore()

        let monitor = UsageMonitor(interval: 3600)
        monitor.attach(store)
        #expect(await waitUntil(timeout: 10) { monitor.sessions.count == 2 })
        #expect(monitor.sessions[demo.claude.id]?.contextPercent == 84.2)
        #expect(monitor.sessions[codexActive.id]?.contextPercent == 20)
        #expect(monitor.claude?.limits.count == 2)
        #expect(monitor.codex?.limits.first?.usedPercent == 80)
        #expect(monitor.sessions[demo.codex.id] == nil) // las archivadas no se leen

        let view = VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatusPill(status: .working, kind: .claude)
                UsageBadge(sessionId: demo.claude.id, monitor: monitor)
                UsageBadge(sessionId: codexActive.id, monitor: monitor)
            }
            Divider()
            UsageSummary(monitor: monitor)
        }
        .padding(14)
        .frame(width: 300, alignment: .topLeading)
        .environment(store)
        // 300 de ancho: el estado y los dos «ctx» entran en una línea, como en la barra de la sesión.
        await check(view, size: CGSize(width: 300, height: 150), name: "ah-08-uso")
        await check(view, size: CGSize(width: 300, height: 150), name: "ah-09-uso-claro", dark: false)
    }
}
