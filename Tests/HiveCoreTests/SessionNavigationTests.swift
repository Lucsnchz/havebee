import Foundation
import Testing
@testable import HiveCore

@Suite("Navegación con el teclado")
struct SessionNavigationTests {
    /// alpha: main (Claude 1) y feature (Codex 1, una archivada, Terminal 1). beta: sin sesiones.
    struct NavFixture {
        let alpha: Project
        let beta: Project
        let scratch: Project
        let s1: Session, s2: Session, s3: Session, archived: Session

        init() {
            s1 = Session(name: "Claude 1", kind: .claude, createdAt: .reference)
            s2 = Session(name: "Codex 1", kind: .codex, createdAt: .reference)
            s3 = Session(name: "Terminal 1", kind: .shell, createdAt: .reference)
            archived = Session(name: "Claude 2", kind: .claude, archivedAt: .reference)
            alpha = Project(name: "alpha", path: "/alpha", branches: [
                Branch(name: "main", mode: .main, sessions: [s1]),
                Branch(name: "feature", mode: .worktree, worktreePath: "/f", sessions: [s2, archived, s3]),
            ])
            beta = Project(name: "beta", path: "/beta")
            scratch = .scratch(home: "/home")
        }

        var projects: [Project] { [alpha, beta, scratch] }
    }

    @Test("Las pestañas siguen el orden de las ramas y dejan afuera las archivadas")
    func orderedTabs() {
        let f = NavFixture()
        #expect(SessionNavigation.orderedSessions(in: f.alpha).map(\.name) == ["Claude 1", "Codex 1", "Terminal 1"])
        let (tabs, _) = ProjectTabs.make(f.alpha)
        #expect(tabs.map(\.branch.name) == ["main", "feature", "feature"])
        #expect(tabs.map(\.id) == [f.s1.id, f.s2.id, f.s3.id])
        #expect(SessionNavigation.orderedSessions(in: f.beta).isEmpty)
    }

    @Test("La rama se muestra solo si hay pestañas de más de una")
    func showBranch() {
        let f = NavFixture()
        #expect(ProjectTabs.make(f.alpha).showBranch)
        #expect(!ProjectTabs.make(f.beta).showBranch)
        var single = f.alpha
        single.branches[0].sessions = []
        #expect(!ProjectTabs.make(single).showBranch) // todas en feature
        var onlyArchived = f.alpha
        onlyArchived.branches[1].sessions = [f.archived]
        #expect(!ProjectTabs.make(onlyArchived).showBranch) // la archivada no cuenta
    }

    @Test("Siguiente y anterior dan la vuelta")
    func adjacentWraps() {
        let f = NavFixture()
        #expect(SessionNavigation.adjacentSession(of: f.s1.id, delta: 1, in: f.alpha) == f.s2.id)
        #expect(SessionNavigation.adjacentSession(of: f.s3.id, delta: 1, in: f.alpha) == f.s1.id)
        #expect(SessionNavigation.adjacentSession(of: f.s1.id, delta: -1, in: f.alpha) == f.s3.id)
        #expect(SessionNavigation.adjacentSession(of: f.s2.id, delta: -1, in: f.alpha) == f.s1.id)
        #expect(SessionNavigation.adjacentSession(of: f.s2.id, delta: 4, in: f.alpha) == f.s3.id)
    }

    @Test("Desde el Resumen va a la primera o a la última; sin pestañas no hay a dónde ir")
    func adjacentFromOutside() {
        let f = NavFixture()
        #expect(SessionNavigation.adjacentSession(of: nil, delta: 1, in: f.alpha) == f.s1.id)
        #expect(SessionNavigation.adjacentSession(of: nil, delta: -1, in: f.alpha) == f.s3.id)
        #expect(SessionNavigation.adjacentSession(of: f.archived.id, delta: 1, in: f.alpha) == f.s1.id)
        #expect(SessionNavigation.adjacentSession(of: nil, delta: 1, in: f.beta) == nil)
    }

    @Test("Proyecto siguiente y anterior en el orden del sidebar")
    func adjacentProjects() {
        let f = NavFixture()
        #expect(SessionNavigation.adjacentProject(of: f.alpha.id, delta: 1, in: f.projects) == f.beta.id)
        #expect(SessionNavigation.adjacentProject(of: f.scratch.id, delta: 1, in: f.projects) == f.alpha.id)
        #expect(SessionNavigation.adjacentProject(of: f.alpha.id, delta: -1, in: f.projects) == f.scratch.id)
        #expect(SessionNavigation.adjacentProject(of: nil, delta: 1, in: f.projects) == f.alpha.id)
        #expect(SessionNavigation.adjacentProject(of: nil, delta: 1, in: []) == nil)
    }

    @Test("⌘J: primero la que pide permiso, después la que espera hace más")
    func nextWaitingOrder() {
        let old = UUID(), recent = UUID(), permission = UUID(), seen = UUID()
        let candidates = [
            WaitingCandidate(sessionId: recent, needsPermission: false, unseen: true, lastActivityAt: .reference.addingTimeInterval(60)),
            WaitingCandidate(sessionId: permission, needsPermission: true, unseen: true, lastActivityAt: .reference.addingTimeInterval(120)),
            WaitingCandidate(sessionId: old, needsPermission: false, unseen: true, lastActivityAt: .reference),
            WaitingCandidate(sessionId: seen, needsPermission: false, unseen: false, lastActivityAt: .reference.addingTimeInterval(-600)),
        ]
        #expect(SessionNavigation.nextWaiting(candidates: candidates) == permission)
        // Si ya estás en la que pide permiso, pasa a la que espera hace más.
        #expect(SessionNavigation.nextWaiting(candidates: candidates, excluding: permission) == old)
        #expect(SessionNavigation.nextWaiting(candidates: Array(candidates.dropFirst(2)), excluding: old) == nil)
    }

    @Test("⌘J: entre dos que piden permiso, la más vieja; sin fecha cuenta como la más vieja")
    func nextWaitingTies() {
        let a = UUID(), b = UUID(), undated = UUID()
        let candidates = [
            WaitingCandidate(sessionId: a, needsPermission: true, unseen: false, lastActivityAt: .reference.addingTimeInterval(30)),
            WaitingCandidate(sessionId: b, needsPermission: true, unseen: false, lastActivityAt: .reference),
        ]
        #expect(SessionNavigation.nextWaiting(candidates: candidates) == b)
        let unseen = [
            WaitingCandidate(sessionId: a, needsPermission: false, unseen: true, lastActivityAt: .reference),
            WaitingCandidate(sessionId: undated, needsPermission: false, unseen: true, lastActivityAt: nil),
        ]
        #expect(SessionNavigation.nextWaiting(candidates: unseen) == undated)
        #expect(SessionNavigation.nextWaiting(candidates: []) == nil)
    }

    @Test("Acorta por el medio", arguments: [
        ("main", 18, "main"),
        ("exactamente-18-car", 18, "exactamente-18-car"),
        ("feature/seguridad-checkout", 18, "feature/…-checkout"),
        ("abcdefghij", 5, "ab…ij"),
        ("abcdefghij", 4, "a…ij"),
        ("abcdefghij", 2, "…j"),
        ("abcdefghij", 1, "…"),
        ("abcdefghij", 0, ""),
        ("ñandú-pingüino-cóndor", 9, "ñand…ndor"),
    ])
    func middleTruncated(input: String, max: Int, expected: String) {
        let result = input.middleTruncated(max: max)
        #expect(result == expected)
        #expect(result.count <= Swift.max(max, 0))
    }
}
