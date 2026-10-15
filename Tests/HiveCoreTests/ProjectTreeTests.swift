import Foundation
import Testing
@testable import HiveCore

@Suite("Árbol de proyectos")
struct ProjectTreeTests {
    /// Dos repos y «Terminales»: alpha (main + feature con 3 sesiones, una archivada) y beta.
    struct Fixture {
        var projects: [Project]
        let alpha: Project
        let beta: Project
        let main: Branch
        let feature: Branch
        let s1: Session, s2: Session, s3: Session, archived: Session

        init() {
            s1 = Session(name: "Claude 1", kind: .claude, createdAt: .reference)
            s2 = Session(name: "Codex 1", kind: .codex, createdAt: .reference.addingTimeInterval(5))
            s3 = Session(name: "Terminal 1", kind: .shell, createdAt: .reference.addingTimeInterval(1))
            archived = Session(name: "Claude 2", kind: .claude, archivedAt: .reference)
            main = Branch(name: "main", mode: .main, sessions: [s1])
            feature = Branch(name: "feature", mode: .worktree, worktreePath: "/alpha.worktrees/feature", sessions: [s2, archived, s3])
            alpha = Project(name: "alpha", path: "/alpha", branches: [main, feature])
            beta = Project(name: "beta", path: "/beta")
            projects = [alpha, beta, .scratch(home: "/home")]
        }
    }

    @Test("Busca proyectos, ramas y sesiones")
    func lookups() throws {
        let f = Fixture()
        #expect(f.projects.project(f.beta.id)?.name == "beta")
        #expect(f.projects.project(UUID()) == nil)
        let branch = try #require(f.projects.branchContext(f.feature.id))
        #expect(branch.project.id == f.alpha.id)
        #expect(branch.branch.name == "feature")
        let session = try #require(f.projects.sessionContext(f.s3.id))
        #expect(session.branch.id == f.feature.id && session.project.id == f.alpha.id)
        #expect(f.projects.sessionContext(UUID()) == nil)
        #expect(f.projects.repos.map(\.name) == ["alpha", "beta"])
        #expect(f.projects.scratch?.isScratch == true)
    }

    @Test("Proyecto de cada elemento del sidebar")
    func projectOfItem() {
        let f = Fixture()
        #expect(f.projects.projectId(of: .project(f.beta.id)) == f.beta.id)
        #expect(f.projects.projectId(of: .branch(f.feature.id)) == f.alpha.id)
        #expect(f.projects.projectId(of: .session(f.s1.id)) == f.alpha.id)
        #expect(f.projects.projectId(of: nil) == nil)
        #expect(f.projects.projectId(of: .session(UUID())) == nil)
        #expect(f.projects.contains(.session(f.s2.id), inProject: f.alpha.id))
        #expect(!f.projects.contains(.session(f.s2.id), inProject: f.beta.id))
    }

    @Test("Cambia proyectos, ramas y sesiones (y avisa si no existen)")
    func updates() {
        var f = Fixture()
        #expect(f.projects.updateProject(f.beta.id) { $0.name = "Beta" })
        #expect(f.projects.updateBranch(f.main.id) { $0.color = .red })
        #expect(f.projects.updateSession(f.s2.id) { $0.name = "Renombrada" })
        #expect(!f.projects.updateSession(UUID()) { $0.name = "x" })
        #expect(!f.projects.updateBranch(UUID()) { $0.name = "x" })
        #expect(!f.projects.updateProject(UUID()) { $0.name = "x" })
        #expect(f.projects.project(f.beta.id)?.name == "Beta")
        #expect(f.projects.branchContext(f.main.id)?.branch.color == .red)
        #expect(f.projects.sessionContext(f.s2.id)?.session.name == "Renombrada")
    }

    @Test("Los repos nuevos van antes de «Terminales»")
    func insertRepo() {
        var f = Fixture()
        f.projects.insertRepo(Project.make("gamma"))
        #expect(f.projects.map(\.name) == ["alpha", "beta", "gamma", "Terminales"])
        var noScratch = [Project.make("a")]
        noScratch.insertRepo(Project.make("b"))
        #expect(noScratch.map(\.name) == ["a", "b"])
    }

    @Test("«Terminales» se crea una sola vez y siempre queda última")
    func ensureScratch() {
        var empty: [Project] = []
        empty.ensureScratch(home: "/h")
        #expect(empty.map(\.name) == ["Terminales"])
        empty.ensureScratch(home: "/h")
        #expect(empty.count == 1)

        var misplaced = [Project.scratch(home: "/h"), .make("a"), .make("b")]
        misplaced.ensureScratch(home: "/h")
        #expect(misplaced.map(\.name) == ["a", "b", "Terminales"])
    }

    @Test("Mover repos deja «Terminales» al final")
    func moveRepos() {
        var f = Fixture()
        f.projects.moveRepos(fromOffsets: [1], toOffset: 0)
        #expect(f.projects.map(\.name) == ["beta", "alpha", "Terminales"])
    }

    @Test("Posición entre hermanos (las archivadas no cuentan)")
    func positions() throws {
        let f = Fixture()
        #expect(try #require(f.projects.position(of: .project(f.alpha.id))) == (0, 2))
        #expect(try #require(f.projects.position(of: .branch(f.feature.id))) == (1, 2))
        #expect(try #require(f.projects.position(of: .session(f.s3.id))) == (1, 2))
        #expect(f.projects.position(of: .session(f.archived.id)) == nil)
        #expect(f.projects.position(of: .project(f.projects[2].id)) == nil) // «Terminales» no se mueve
    }

    @Test("Subir y bajar respeta los bordes")
    func moveByOne() {
        var f = Fixture()
        let r1 = f.projects.move(.project(f.alpha.id), by: -1)
        #expect(!r1)
        let r2 = f.projects.move(.project(f.alpha.id), by: 1)
        #expect(r2)
        #expect(f.projects.map(\.name) == ["beta", "alpha", "Terminales"])
        let r3 = f.projects.move(.project(f.alpha.id), by: 1)
        #expect(!r3)
        let r4 = f.projects.move(.branch(f.feature.id), by: -1)

        #expect(r4)
        #expect(f.projects.project(f.alpha.id)?.branches.map(\.name) == ["feature", "main"])

        let r5 = f.projects.move(.session(f.s3.id), by: -1)

        #expect(r5)
        let sessions = f.projects.branchContext(f.feature.id)?.branch.sessions.map(\.name)
        // La archivada queda al final.
        #expect(sessions == ["Terminal 1", "Codex 1", "Claude 2"])
        let r6 = f.projects.move(.session(UUID()), by: 1)
        #expect(!r6)
    }

    @Test("Mover sesiones deja las archivadas al final")
    func moveActiveSessions() {
        var branch = Fixture().feature
        branch.moveActiveSessions(fromOffsets: [0], toOffset: 2)
        #expect(branch.sessions.map(\.name) == ["Terminal 1", "Codex 1", "Claude 2"])
    }

    @Test("Nombres de sesiones nuevas")
    func nextSessionName() {
        var branch = Branch(name: "main", mode: .main)
        #expect(branch.nextSessionName(for: .claude) == "Claude 1")
        branch.sessions = [Session(name: "Claude 1", kind: .claude), Session(name: "Claude 3", kind: .claude)]
        #expect(branch.nextSessionName(for: .claude) == "Claude 4")
        #expect(branch.nextSessionName(for: .codex) == "Codex 1")
        // Si renombraste una sesión con el nombre que tocaba, se saltea.
        branch.sessions = [Session(name: "Codex 1", kind: .claude)]
        #expect(branch.nextSessionName(for: .codex) == "Codex 2")
    }

    @Test("Pestaña vecina al archivar")
    func neighbor() {
        let f = Fixture()
        // Sesiones activas de alpha en orden: Claude 1, Codex 1, Terminal 1.
        #expect(f.alpha.neighborSession(of: f.s1.id) == f.s2.id)
        #expect(f.alpha.neighborSession(of: f.s3.id) == f.s2.id)
        #expect(f.beta.neighborSession(of: f.s1.id) == nil)
        let lonely = Project.make(branches: [Branch(name: "m", mode: .main, sessions: [f.s1])])
        #expect(lonely.neighborSession(of: f.s1.id) == nil)
    }

    @Test("Sesión a abrir al elegir un proyecto")
    func sessionToOpen() {
        let f = Fixture()
        #expect(f.alpha.sessionToOpen(last: f.s3.id) == f.s3.id)
        // La última fue archivada: abre la usada más recientemente (Codex 1).
        #expect(f.alpha.sessionToOpen(last: f.archived.id) == f.s2.id)
        #expect(f.alpha.sessionToOpen(last: nil) == f.s2.id)
        #expect(f.beta.sessionToOpen(last: nil) == nil)
    }

    @Test("Rama activa y rama principal")
    func activeBranch() {
        let f = Fixture()
        #expect(f.alpha.isActive(f.feature, head: "otra")) // worktree: siempre activa
        #expect(f.alpha.isActive(f.main, head: "main"))
        #expect(!f.alpha.isActive(f.main, head: "develop"))
        #expect(!f.alpha.isActive(f.main, head: nil))
        let scratch = Project.scratch(home: "/h")
        #expect(scratch.isActive(scratch.branches[0], head: nil))
        #expect(f.alpha.mainBranch(head: "main")?.id == f.main.id)
        #expect(f.alpha.mainBranch(head: "nada")?.id == f.main.id) // la primera
        #expect(f.beta.mainBranch(head: "main") == nil) // sin ramas
    }

    @Test("IDs de conversación usados por otras sesiones")
    func claimedIds() {
        var f = Fixture()
        f.projects.updateSession(f.s1.id) { $0.agentSessionId = "uno" }
        f.projects.updateSession(f.archived.id) { $0.agentSessionId = "dos" }
        f.projects.updateSession(f.s2.id) { $0.agentSessionId = "tres" }
        #expect(f.projects.claimedAgentIds(.claude, except: f.s1.id) == ["dos"])
        #expect(f.projects.claimedAgentIds(.claude, except: UUID()) == ["uno", "dos"])
        #expect(f.projects.claimedAgentIds(.codex, except: UUID()) == ["tres"])
    }

    @Test("moveItems como el de SwiftUI", arguments: [
        ([0], 3, ["b", "c", "a", "d"]),
        ([3], 0, ["d", "a", "b", "c"]),
        ([0, 1], 4, ["c", "d", "a", "b"]),
        ([2], 2, ["a", "b", "c", "d"]),
        ([9], 0, ["a", "b", "c", "d"]), // índice inválido: no hace nada
    ])
    func moveItems(source: [Int], destination: Int, expected: [String]) {
        var items = ["a", "b", "c", "d"]
        items.moveItems(fromOffsets: IndexSet(source), toOffset: destination)
        #expect(items == expected)
    }
}

@Suite("Lógica de proyectos")
struct ProjectLogicTests {
    @Test("Agrega worktrees nuevos y deja afuera los que no corresponden")
    func syncAddsWorktrees() throws {
        let project = Project.make(path: "/repo", branches: [Branch(name: "main", mode: .main)])
        let worktrees = [
            GitWorktree(path: "/repo", branch: "main"),          // la carpeta principal
            GitWorktree(path: "/wt/nueva", branch: "nueva"),     // nueva
            GitWorktree(path: "/wt/suelta", branch: nil),        // HEAD desacoplado
            GitWorktree(path: "/wt/borrada", branch: "borrada"), // la carpeta ya no existe
        ]
        let result = try #require(WorktreeSync.apply(worktrees, to: project, exists: { $0 != "/wt/borrada" }))
        #expect(result.project.branches.map(\.name) == ["main", "nueva"])
        #expect(result.project.branches[1].mode == .worktree)
        #expect(result.project.branches[1].worktreePath == "/wt/nueva")
        #expect(result.added == [result.project.branches[1].id])
    }

    @Test("Una rama de la carpeta principal que pasó a un worktree se convierte")
    func syncConvertsMainBranch() throws {
        let project = Project.make(path: "/repo", branches: [Branch(name: "main", mode: .main), Branch(name: "fix", mode: .main)])
        let result = try #require(WorktreeSync.apply([GitWorktree(path: "/wt/fix", branch: "fix")], to: project, exists: { _ in true }))
        #expect(result.project.branches[1].mode == .worktree)
        #expect(result.project.branches[1].worktreePath == "/wt/fix")
        #expect(result.added.isEmpty)
    }

    @Test("Un worktree movido actualiza su ruta; si sigue en su lugar no cambia")
    func syncMovedWorktree() throws {
        let project = Project.make(path: "/repo", branches: [Branch(name: "x", mode: .worktree, worktreePath: "/viejo/x")])
        let moved = try #require(WorktreeSync.apply([GitWorktree(path: "/nuevo/x", branch: "x")], to: project,
                                                     exists: { $0 == "/nuevo/x" }))
        #expect(moved.project.branches[0].worktreePath == "/nuevo/x")
        #expect(WorktreeSync.apply([GitWorktree(path: "/nuevo/x", branch: "x")], to: project, exists: { _ in true }) == nil)
    }

    @Test("Los worktrees ignorados no vuelven y sin cambios devuelve nil")
    func syncIgnored() {
        var project = Project.make(path: "/repo")
        project.ignoredWorktrees = ["/wt/ignorada"]
        #expect(WorktreeSync.apply([GitWorktree(path: "/wt/ignorada", branch: "ignorada")], to: project, exists: { _ in true }) == nil)
        #expect(WorktreeSync.apply([], to: project) == nil)
    }

    @Test("Elige el color menos usado, en el orden de la paleta")
    func defaultColor() {
        #expect(AppearanceDefaults.color(avoiding: []) == .blue)
        #expect(AppearanceDefaults.color(avoiding: [.blue]) == .orange)
        #expect(AppearanceDefaults.color(avoiding: [.blue, .orange]) == .green)
        // Con todos usados una vez, vuelve al primero.
        #expect(AppearanceDefaults.color(avoiding: TintColor.allCases) == .blue)
    }

    @Test("Completa color e ícono sin pisar lo que ya tiene")
    func applyAppearance() {
        var withLogo = Project.make("a", path: "/a")
        AppearanceDefaults.apply(to: &withLogo, others: [Project(name: "b", path: "/b", color: .blue)], logos: { _ in ["/a/logo.png", "/a/otro.png"] })
        #expect(withLogo.color == .orange)
        #expect(withLogo.icon == .image("/a/logo.png"))

        var noLogo = Project.make("c")
        AppearanceDefaults.apply(to: &noLogo, others: [], logos: { _ in [] })
        #expect(noLogo.icon == .initials)

        var custom = Project(name: "d", path: "/d", color: .pink, icon: .emoji("🐝"))
        AppearanceDefaults.apply(to: &custom, others: [], logos: { _ in ["/d/logo.png"] })
        #expect(custom.color == .pink && custom.icon == .emoji("🐝"))

        var scratch = Project.scratch(home: "/h")
        scratch.color = nil
        AppearanceDefaults.apply(to: &scratch, others: [], logos: { _ in ["/x.png"] })
        #expect(scratch.color == nil) // «Terminales» no se toca
    }
}
