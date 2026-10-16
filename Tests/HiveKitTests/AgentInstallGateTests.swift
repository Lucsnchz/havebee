import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Un store sin Gemini instalado (Claude y Codex sí), con «Terminales» abierto.
@MainActor
private final class InstallGateFixture {
    let world = TestWorld()
    let store: AppStore
    let branchId: UUID
    let availability: AgentAvailability

    init() async throws {
        world.processes.installed = ["claude", "codex", "grok"]
        store = world.makeStore()
        branchId = try #require(store.scratchProject?.branches.first?.id)
        store.select(.branch(branchId))
        availability = AgentAvailability.shared(for: store)
        #expect(await waitUntil { availability.checked })
    }

    var sessions: [Session] { store.scratchProject?.branches.first?.sessions ?? [] }
}

@MainActor
@Suite("Agentes no instalados: ⌘T, el menú «Sesión» y ⌘K no crean la sesión")
struct AgentInstallGateTests {
    @Test("⌘T con una sesión de Gemini abierta (y Gemini sin instalar) avisa cómo instalarlo")
    func commandT() async throws {
        let f = try await InstallGateFixture()
        // Una sesión de Gemini que quedó de antes (cuando estaba instalado).
        f.store.requestNewSession(branchId: f.branchId, kind: .gemini)
        let before = f.sessions.count
        #expect(HiveNavigator.newSessionTarget(f.store)?.kind == .gemini)
        HiveNavigator.newSession(f.store)
        #expect(await waitUntil { f.store.alert != nil })
        #expect(f.sessions.count == before)
        let alert = try #require(f.store.alert)
        #expect(alert.title == "Gemini no está instalado")
        #expect(alert.message.contains(SessionKind.gemini.installHint))
        #expect(alert.actionTitle == "Copiar comando")
        #expect(!alert.isDestructive)
    }

    @Test("«Nueva sesión de… › Gemini» y la acción de ⌘K tampoco la crean")
    func menuAndSwitcher() async throws {
        let f = try await InstallGateFixture()
        HiveNavigator.newSession(f.store, kind: .gemini)
        #expect(await waitUntil { f.store.alert != nil })
        #expect(f.sessions.isEmpty)
        f.store.alert = nil

        // Lo que hace ⌘K al elegir «Nueva sesión de Gemini en …».
        await HiveNavigator.requestNewSession(f.store, branchId: f.branchId, kind: .gemini)?.value
        #expect(f.sessions.isEmpty)
        #expect(f.store.alert?.title == "Gemini no está instalado")
        // ⌘K lo muestra como no instalado (con lo que le pasa QuickSwitcher).
        #expect(f.availability.missing == [.gemini])
        let action = SwitcherIndex.search(">nueva gemini", in: f.store.projects, missingAgents: f.availability.missing).first
        #expect(action?.target == .action(.newSession(branch: f.branchId, kind: .gemini)))
        #expect(action?.subtitle == "No instalado · \(SessionKind.gemini.installHint)")
    }

    @Test("Con el agente instalado, la sesión se crea al toque")
    func installedCreatesRightAway() async throws {
        let f = try await InstallGateFixture()
        #expect(HiveNavigator.requestNewSession(f.store, branchId: f.branchId, kind: .codex) == nil)
        #expect(f.sessions.map(\.kind) == [.codex])
        HiveNavigator.requestNewSession(f.store, branchId: f.branchId, kind: .shell)
        #expect(f.sessions.map(\.kind) == [.codex, .shell])
        #expect(f.store.alert == nil)
    }

    @Test("Si lo instalaste después, vuelve a revisar y crea la sesión sin avisar")
    func installedMeanwhile() async throws {
        let f = try await InstallGateFixture()
        f.world.processes.installed.insert("gemini")
        await HiveNavigator.requestNewSession(f.store, branchId: f.branchId, kind: .gemini)?.value
        #expect(f.sessions.map(\.kind) == [.gemini])
        #expect(f.store.alert == nil)
    }
}
