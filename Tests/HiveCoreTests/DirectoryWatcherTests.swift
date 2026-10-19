import Foundation
import Testing
@testable import HiveCore

/// Junta lo que avisa el watcher hasta que se cumple `condition` (o pasan 10 s: con la máquina
/// cargada, macOS puede tardar en avisar).
private func collect(_ watcher: DirectoryWatching, until condition: (DirectoryChanges) -> Bool) async -> DirectoryChanges {
    var seen = DirectoryChanges()
    let deadline = Date().addingTimeInterval(10)
    while !condition(seen) && Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
        let changes = watcher.drain()
        seen.roots.formUnion(changes.roots)
        seen.all = seen.all || changes.all
    }
    return seen
}

@Suite("Avisos de cambios en carpetas")
struct DirectoryWatcherTests {
    @Test("Anota cada cambio en la carpeta mirada más específica que lo contiene")
    func mostSpecificRoot() async {
        let dir = TempDir()
        let repo = dir.subdir("repo").path
        let gitDir = dir.subdir("repo/.git").path
        let other = dir.subdir("otra").path
        let watcher = FSEventsDirectoryWatcher(latency: 0.05)
        watcher.watch([repo, gitDir, other])
        #expect(watcher.drain().all) // lo de antes de empezar a mirar no se sabe
        #expect(watcher.drain() == DirectoryChanges())

        dir.write("repo/src/main.swift", "print(1)")
        let files = await collect(watcher) { $0.roots.contains(repo) }
        #expect(files.roots == [repo])

        dir.write("repo/.git/HEAD", "ref: refs/heads/otra\n")
        let git = await collect(watcher) { $0.roots.contains(gitDir) }
        #expect(git.roots == [gitDir])
    }

    @Test("Leer git no se avisa a sí mismo: si no, cada revisión pediría otra")
    func readingGitIsQuiet() async throws {
        let repo = GitRepo()
        repo.write("nuevo.txt", "sin commitear\n")
        let gitDir = (repo.path as NSString).appendingPathComponent(".git")
        let watcher = FSEventsDirectoryWatcher(latency: 0.05)
        watcher.watch([repo.path, gitDir])
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = watcher.drain()

        // Lo mismo que lee una revisión.
        let git = GitCLI()
        #expect(git.status(repo.path)?.changes.isEmpty == false)
        #expect(git.currentBranch(repo.path) == "main")
        _ = git.localBranches(repo.path)
        _ = git.remoteBranches(repo.path)
        _ = git.worktrees(repo.path)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(watcher.drain() == DirectoryChanges())

        // Y sigue mirando.
        repo.write("otro.txt", "hola\n")
        #expect(await collect(watcher) { $0.roots.contains(repo.path) }.roots == [repo.path])
    }

    @Test("Mira una carpeta que todavía no existe, aunque su ruta pase por un enlace (/var)")
    func missingRoot() async {
        let dir = TempDir()
        let real = dir.url.appendingPathComponent("worktree").path
        // La ruta como la da NSTemporaryDirectory(): /var/folders/…, un enlace a /private/var.
        let linked = real.hasPrefix("/private/var/") ? String(real.dropFirst("/private".count)) : real
        let watcher = FSEventsDirectoryWatcher(latency: 0.05)
        watcher.watch([linked])
        _ = watcher.drain()
        dir.write("worktree/README.md", "# Hola\n")
        #expect(await collect(watcher) { $0.roots.contains(linked) }.roots == [linked])
    }

    @Test("Cambiar las carpetas empieza de cero; mirar las mismas, no")
    func newRootsStartOver() {
        let dir = TempDir()
        let a = dir.subdir("a").path
        let b = dir.subdir("b").path
        let watcher = FSEventsDirectoryWatcher(latency: 0.05)
        #expect(watcher.drain() == DirectoryChanges()) // sin carpetas no hay nada que avisar
        watcher.watch([a])
        #expect(watcher.drain().all)
        watcher.watch([a])
        #expect(watcher.drain() == DirectoryChanges())
        watcher.watch([a, b])
        #expect(watcher.drain().all)
        watcher.watch([])
        #expect(watcher.drain() == DirectoryChanges())
    }

    @Test("Sin mirar, siempre cambió todo")
    func unwatched() {
        let watcher = UnwatchedDirectories()
        watcher.watch(["/a"])
        #expect(watcher.drain().all)
        #expect(watcher.drain().all)
    }
}

@Suite("Qué hay que volver a leer de git")
struct GitStalenessTests {
    private let layout = GitLayout(repositories: [
        .init(path: "/tienda", worktrees: ["/wt/tienda-pagos"], gitDirectories: ["/tienda/.git"]),
        .init(path: "/plagas", worktrees: [], gitDirectories: ["/plagas/.git"]),
    ])

    @Test("Las carpetas a mirar: las de trabajo y las de git")
    func roots() {
        #expect(layout.roots == ["/tienda", "/wt/tienda-pagos", "/tienda/.git", "/plagas", "/plagas/.git"])
    }

    @Test("Un cambio en los archivos de una carpeta: solo su estado")
    func treeChange() {
        var stale = GitStaleness()
        stale.record(DirectoryChanges(roots: ["/wt/tienda-pagos"]), in: layout)
        #expect(stale.statuses == ["/wt/tienda-pagos"])
        #expect(stale.repositories.isEmpty)
    }

    @Test("Un cambio en los datos de git: todo lo de ese repo, worktrees incluidos")
    func gitChange() {
        var stale = GitStaleness()
        stale.record(DirectoryChanges(roots: ["/tienda/.git"]), in: layout)
        #expect(stale.statuses == ["/tienda", "/wt/tienda-pagos"])
        #expect(stale.repositories == ["/tienda"])
    }

    @Test("Si no se sabe qué cambió, todo; lo que se lee deja de estar pendiente")
    func everythingAndClear() {
        var stale = GitStaleness()
        stale.record(DirectoryChanges(roots: ["/no-es-de-hive"], all: true), in: layout)
        #expect(stale.statuses == ["/tienda", "/wt/tienda-pagos", "/plagas"])
        #expect(stale.repositories == ["/tienda", "/plagas"])
        stale.clear(statuses: ["/tienda", "/plagas"], repositories: ["/plagas"])
        #expect(stale.statuses == ["/wt/tienda-pagos"])
        #expect(stale.repositories == ["/tienda"])
        stale.markStatus("/plagas")
        stale.markRepository("/plagas")
        #expect(stale.statuses == ["/wt/tienda-pagos", "/plagas"])
        #expect(stale.repositories == ["/tienda", "/plagas"])
    }

    @Test("Dónde guarda git los datos: el .git, o la carpeta a la que apunta y la común")
    func gitDirectories() {
        let repo = GitRepo()
        let worktree = (repo.dir.path as NSString).appendingPathComponent("pagos")
        repo.sh("git worktree add -q -b pagos \(shellQuote(worktree))")
        let dotGit = (repo.path as NSString).appendingPathComponent(".git")
        #expect(GitLayout.gitDirectories(of: repo.path) == [dotGit])
        // Foundation deja /var en lugar de /private/var: la misma carpeta (el watcher resuelve los enlaces).
        #expect(GitLayout.gitDirectories(of: worktree).map(TempDir.realPath) == [(dotGit as NSString).appendingPathComponent("worktrees/pagos"), dotGit])
        #expect(GitLayout.gitDirectories(of: repo.dir.path).isEmpty)
    }
}
