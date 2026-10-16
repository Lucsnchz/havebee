import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Dibuja una vista fuera de pantalla, en oscuro o en claro, y guarda la captura si hay HIVE_SNAPSHOTS.
@MainActor
private func gitHerdRender<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = true, settle: TimeInterval = 0.8) async -> NSBitmapImageRep? {
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

/// Herd falso dentro del home del mundo de prueba: sirve la carpeta padre del repo y el principal tiene HTTPS.
@MainActor
private func gitHerdFakeHerd(home: URL, parked: String, secured: [String]) throws {
    let valet = HerdSites.defaultRoot(home: home).appendingPathComponent("config/valet")
    try FileManager.default.createDirectory(at: valet.appendingPathComponent("Sites"), withIntermediateDirectories: true)
    let certs = valet.appendingPathComponent("Certificates")
    try FileManager.default.createDirectory(at: certs, withIntermediateDirectories: true)
    try #"{"paths": ["\#(parked)/"], "tld": "test"}"#.write(to: valet.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    for host in secured { FileManager.default.createFile(atPath: certs.appendingPathComponent("\(host).crt").path, contents: Data()) }
}

@MainActor
@Suite("Vistas de git y Herd", .serialized)
struct GitHerdViewTests {
    func check(_ view: some View, size: CGSize, name: String, dark: Bool = true) async {
        // @AppStorage de la hoja (newBranchMode, newBranchFirstSession) en un dominio propio, nunca en .standard.
        let suite = "hive-git-herd-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("No se pudo crear el dominio \(suite)")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let rep = await gitHerdRender(view.defaultAppStorage(defaults), size: size, name: name, dark: dark)
        #expect(rep != nil, "No se pudo dibujar \(name)")
    }

    @Test("Crear un worktree desde el store: carpeta hermana, solo los .env ignorados y APP_URL reescrito")
    func createReadyWorktree() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "ecommerce")
        repo.write(".gitignore", ".env\n")
        repo.write(".env.example", "APP_URL=http://localhost\n")
        repo.commit("Base")
        repo.write(".env", "APP_URL=https://ecommerce.test\nSESSION_DOMAIN=ecommerce.test\n")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        let error = await store.createBranch(NewBranchRequest(
            projectId: project.id, name: "feature/checkout", isNew: true, base: "main", mode: .worktree,
            location: .sibling, copyIgnored: true, envAppURL: "http://ecommerce-checkout.test"))
        #expect(error == nil)
        let branch = try #require(store.project(project.id)?.branches.last)
        let path = try #require(branch.worktreePath)
        #expect(path == repo.dir.url.path + "/ecommerce-checkout")
        let env = try String(contentsOfFile: path + "/.env", encoding: .utf8)
        #expect(env == "APP_URL=http://ecommerce-checkout.test\nSESSION_DOMAIN=ecommerce-checkout.test\n")
    }

    @Test("Las URLs de MR de GitLab se pueden abrir aunque tengan corchetes")
    func browserLinks() throws {
        let remote = try #require(RemoteHost.parse("git@gitlab.com:dizeg/ecommerce.git"))
        let url = try #require(remote.newMergeRequestURL(source: "feature/x", target: "main"))
        #expect(BrowserLink.url(url) != nil)
        #expect(BrowserLink.url("https://ecommerce.test")?.host == "ecommerce.test")
    }

    @Test("Nueva rama con Herd: carpeta hermana, copia, preparación y chips de la primera sesión")
    func newBranchWithHerd() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "ecommerce")
        repo.write(".gitignore", ".env\nauth.json\n")
        repo.write("composer.json", "{}")
        repo.write("package.json", #"{"scripts": {"build": "vite build"}}"#)
        repo.commit("Laravel")
        repo.write(".env", "APP_URL=https://ecommerce.test\n")
        repo.write("auth.json", "{}")
        try gitHerdFakeHerd(home: world.home, parked: repo.dir.path, secured: ["ecommerce.test"])
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        let project = try #require(store.repoProjects.first)
        await check(NewBranchSheet(projectId: project.id).environment(store), size: CGSize(width: 500, height: 760), name: "git-01-nueva-rama-herd")
        await check(NewBranchSheet(projectId: project.id).environment(store), size: CGSize(width: 500, height: 760),
                    name: "git-01b-nueva-rama-herd-claro", dark: false)
        await check(OpenSiteButton(project: project, branch: project.branches[0]).environment(store).padding(),
                    size: CGSize(width: 220, height: 60), name: "git-03-abrir-sitio")
    }

    @Test("Nueva rama en un repo sin commits")
    func newBranchWithoutCommits() async throws {
        let world = TestWorld()
        let dir = TempDir()
        #expect(GitCLI().initRepository(dir.path).ok)
        let store = world.makeStore()
        await store.addProject(at: dir.path)
        let project = try #require(store.repoProjects.first)
        await check(NewBranchSheet(projectId: project.id).environment(store), size: CGSize(width: 500, height: 300), name: "git-04-nueva-rama-sin-commits")
    }

    @Test("Diff de un archivo en conflicto, en oscuro y en claro, y el menú del remoto")
    func conflictDiff() async throws {
        let world = TestWorld()
        let repo = GitRepo(name: "bevo")
        repo.write("app/Order.php", "<?php\n$total = 0;\n")
        repo.commit("Base")
        repo.sh("git checkout -q -b feat")
        repo.write("app/Order.php", "<?php\n$total = $subtotal;\n")
        repo.commit("Ellos")
        repo.sh("git checkout -q main")
        repo.write("app/Order.php", "<?php\n$total = $subtotal + $envio;\n")
        repo.commit("Nosotros")
        repo.sh("git merge feat")
        repo.sh("git mv README.md LEEME.md")
        // Remoto con forma de GitLab: el menú solo lee la URL, no se conecta.
        repo.sh("git remote add origin git@gitlab.com:dizeg/bevo.git")
        let store = world.makeStore()
        await store.addProject(at: repo.path)
        await store.refreshGitNow()
        let project = try #require(store.repoProjects.first)
        let status = try #require(store.gitStatus(for: project.branches[0], in: project))
        #expect(status.operation == .merge)
        let conflict = try #require(status.changes.first { $0.isConflict })
        let target = DiffTarget.make(directory: repo.path, status: status, change: conflict, staged: false)
        await check(DiffSheet(target: target).environment(store), size: CGSize(width: 1060, height: 520), name: "git-02-diff-conflicto")
        await check(DiffSheet(target: target).environment(store), size: CGSize(width: 900, height: 520), name: "git-02b-diff-conflicto-claro", dark: false)
        let renamed = try #require(status.changes.first { $0.originalPath != nil })
        let renameTarget = DiffTarget.make(directory: repo.path, status: status, change: renamed, staged: true)
        await check(DiffSheet(target: renameTarget).environment(store), size: CGSize(width: 900, height: 500), name: "git-02c-diff-renombre")
        await check(RemoteActionsMenu(project: project, branch: project.branches[0]).environment(store).padding(),
                    size: CGSize(width: 200, height: 60), name: "git-05-menu-remoto")
    }
}
