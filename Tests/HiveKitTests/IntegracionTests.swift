import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Arreglos que aparecieron al juntar los paquetes.
@Suite("Integración")
struct IntegracionTests {
    @Test("Los commits recientes se vuelven a leer cuando cambia HEAD, aunque no haya upstream")
    func recentCommitsRefreshKeyUsesHeadOid() {
        var status = GitStatus(branch: "main", headOid: "aaa111")
        let before = RecentCommits.refreshKey(status)
        status.headOid = "bbb222"
        #expect(RecentCommits.refreshKey(status) != before)
        // Sin oid (repo sin commits) se sigue usando la clave anterior.
        status.headOid = nil
        #expect(RecentCommits.refreshKey(status) == "main|0|0|0")
        #expect(RecentCommits.refreshKey(nil) == "-")
    }
}

/// Las piezas que cablea la integración, dibujadas de verdad (con `HIVE_SNAPSHOTS` quedan en PNG).
@MainActor
@Suite("Integración: vistas", .serialized)
struct IntegracionViewTests {
    /// Un repo con una sesión de Claude lanzada (con procesos falsos).
    private func storeWithClaude() async throws -> (TestWorld, GitRepo, AppStore, Project, Session) {
        let world = TestWorld()
        let repo = GitRepo(name: "tienda")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        store.requestNewSession(branchId: project.branches[0].id, kind: .claude)
        let session = try #require(store.project(project.id)?.branches[0].sessions.first)
        store.activate(session.id)
        #expect(await waitUntil { store.runtimes[session.id]?.terminal != nil })
        store.select(nil)
        return (world, repo, store, project, session)
    }

    /// Dibuja en oscuro y en claro. `empty`: lo que se espera es que no dibuje nada (solo el fondo).
    private func check(_ view: some View, size: CGSize, name: String, empty: Bool = false) async {
        let defaults = SnapshotDefaults()
        let reps = await Snapshot.render(view, size: size, name: name, defaults: defaults.defaults)
        #expect(reps.count == 2, "No se pudo dibujar \(name)")
        for rep in reps {
            if empty {
                #expect(Snapshot.distinctColors(rep) == 1, "\(name) tendría que estar vacía")
            } else {
                #expect(Snapshot.distinctColors(rep) > 3, "\(name) parece vacía")
            }
        }
    }

    @Test("La tarjeta de una sesión que pide permiso muestra el pedido")
    func attentionCard() async throws {
        let (world, repo, store, project, session) = try await storeWithClaude()
        defer { withExtendedLifetime((world, repo)) {} }
        store.handle([HiveEvent(sessionId: session.id, source: "claude", name: "PermissionRequest",
                                payload: ["tool_name": "Bash", "tool_input": ["command": "php artisan migrate"]])])
        #expect(store.runtimes[session.id]?.notice != nil)
        await check(NavigationStack { BranchDetailView(branchId: project.branches[0].id) }.environment(store),
                    size: CGSize(width: 1000, height: 640), name: "19-rama-permiso")
    }

    @Test("Un aviso suelto en la cápsula de abajo, sin «Deshacer»")
    func noticeToast() async throws {
        let world = TestWorld()
        let store = world.makeStore()
        store.showNotice("Copié .env, auth.json y 2 más a «feature/checkout»")
        #expect(store.undoAction?.canUndo == false)
        await check(ZStack(alignment: .bottom) { Color.clear; UndoToastView().padding(.bottom, 16) }.environment(store),
                    size: CGSize(width: 560, height: 120), name: "20-aviso-copie")
    }

    @Test("Encabezado de la rama y barra de la sesión con «Abrir sitio» y el menú de GitLab")
    func webActions() async throws {
        let (world, repo, store, project, session) = try await storeWithClaude()
        defer { withExtendedLifetime((world, repo)) {} }
        repo.sh("git remote add origin git@gitlab.com:dizeg/tienda.git")
        repo.write("polyscope.json", #"{"preview": {"url": "https://{{folder}}.test"}}"#)
        await check(NavigationStack { BranchDetailView(branchId: project.branches[0].id) }.environment(store),
                    size: CGSize(width: 1000, height: 420), name: "21-rama-sitio-y-remoto")
        await check(NavigationStack { SessionDetailView(sessionId: session.id) }.environment(store),
                    size: CGSize(width: 1200, height: 500), name: "22-sesion-sitio-y-remoto")
        // Sin sitio ni remoto no ocupan lugar.
        let plain = try await storeWithClaude()
        defer { withExtendedLifetime((plain.0, plain.1)) {} }
        await check(BranchWebActions(project: plain.3, branch: plain.3.branches[0]).environment(plain.2).padding(20),
                    size: CGSize(width: 300, height: 80), name: "23-sin-sitio-ni-remoto", empty: true)
    }

    @Test("Límites de las cuentas: al pie del sidebar y, en chiquito, en el riel compacto")
    func usageSummary() async throws {
        let (world, repo, store, _, session) = try await storeWithClaude()
        defer { withExtendedLifetime((world, repo)) {} }
        let soon = Int(Date().addingTimeInterval(2 * 3600).timeIntervalSince1970)
        let later = Int(Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970)
        try FileManager.default.createDirectory(at: world.paths.usageDir, withIntermediateDirectories: true)
        try #"{"context_window":{"used_percentage":72},"rate_limits":{"five_hour":{"used_percentage":23,"resets_at":\#(soon)},"seven_day":{"used_percentage":87,"resets_at":\#(later)}}}"#
            .write(to: world.paths.usageDir.appendingPathComponent("\(session.id.uuidString).json"), atomically: true, encoding: .utf8)
        let monitor = UsageMonitor(interval: 3600)
        monitor.attach(store)
        #expect(await waitUntil { monitor.claude != nil })
        #expect(monitor.sessions[session.id]?.contextPercent == 72)
        await check(UsageSummary(monitor: monitor, compact: true).environment(store).frame(width: 72).padding(.vertical, 12),
                    size: CGSize(width: 72, height: 60), name: "24-uso-riel")
        await check(UsageSummary(monitor: monitor).environment(store).padding(12),
                    size: CGSize(width: 240, height: 70), name: "25-uso-sidebar")
        await check(UsageBadge(sessionId: session.id, monitor: monitor).environment(store).padding(12),
                    size: CGSize(width: 100, height: 44), name: "26-uso-sesion")
        // Sin datos no ocupa lugar.
        let empty = UsageMonitor(interval: 3600)
        await check(UsageSummary(monitor: empty, compact: true, insets: EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                        .environment(TestWorld().makeStore()),
                    size: CGSize(width: 72, height: 40), name: "27-uso-vacio", empty: true)
    }

    @Test("La ayuda del riel lista cada límite con su reinicio")
    func usageRailHelp() {
        let now = Date(timeIntervalSince1970: 1_790_942_400)
        let resets = now.addingTimeInterval(3 * 86_400)
        let limits = [UsageLimit(windowMinutes: 300, usedPercent: 23.4, resetsAt: nil),
                      UsageLimit(windowMinutes: 10080, usedPercent: 87, resetsAt: resets)]
        #expect(UsageRailRow.helpText(.codex, limits: limits, now: now)
                == "Codex · 5 horas: 23 % usado · semana: 87 % usado, \(UsageReader.resetText(resets, now: now))")
    }

    @Test("Ajustes avisa si el notify de Codex no se puede leer (y no se va a llamar)")
    func codexNotifyWarning() async throws {
        let dir = TempDir("hive-codex-notify")
        let agents = AgentStorage(claudeConfigDir: dir.subdir("claude"), codexHome: dir.subdir("codex"), geminiHome: dir.subdir("gemini"))
        #expect(SettingsGeneralPane.codexNotifyWarning(agents) == nil) // sin config.toml
        dir.write("codex/config.toml", "notify = ['/usr/local/bin/aviso', 'turno']\n")
        #expect(SettingsGeneralPane.codexNotifyWarning(agents) == nil)
        dir.write("codex/config.toml", "notify = '/usr/local/bin/aviso'\n")
        let warning = try #require(SettingsGeneralPane.codexNotifyWarning(agents))
        #expect(warning.contains("config.toml"))
        await check(SettingsGeneralPane(dataFolder: dir.url, agents: agents), size: CGSize(width: 540, height: 520),
                    name: "28-ajustes-notify-codex")
    }
}
