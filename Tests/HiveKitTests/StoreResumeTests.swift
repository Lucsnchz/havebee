import AppKit
import CryptoKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Un store cargado de un estado guardado, con sesiones que ya se lanzaron antes.
@MainActor
private final class ResumeWorld {
    let world = TestWorld()
    let repo = GitRepo()
    var store: AppStore!

    /// Guarda un estado con estas sesiones en la rama principal y lo carga.
    func load(_ sessions: [Session]) {
        let project = Project(name: "repo", path: repo.path, branches: [Branch(name: "main", mode: .main, sessions: sessions)])
        try! StateStore(file: world.paths.stateFile).save(HiveState(projects: [project], mainHeads: [project.id: "main"]))
        store = world.makeStore()
    }

    func launchArgs(_ id: UUID) throws -> [String] {
        let before = world.processes.launches.count
        store.activate(id)
        #expect(world.processes.launches.count == before + 1)
        return try #require(world.processes.launches.last).args
    }

    /// Un archivo de sesión de Codex como los que escribe en <home>/sessions/AAAA/MM/DD.
    func codexThread(_ id: String, cwd: String, modified: Date) throws {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: modified)
        let dir = world.agents.codexHome.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-\(id).jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\"}}\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    /// Un chat de Gemini como los que guarda en <home>/tmp/<hash>/chats.
    func geminiChat(_ id: String, cwd: String, modified: Date) throws {
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let dir = world.agents.geminiHome.appendingPathComponent("tmp/\(hash)/chats")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session-\(id).json")
        try "{\"sessionId\":\"\(id)\",\"projectHash\":\"\(hash)\",\"messages\":[]}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }
}

@MainActor
@Suite("Store: retomar conversaciones")
struct StoreResumeTests {
    @Test("Claude retoma con --resume si existe la conversación, y con --session-id si no")
    func claudeResume() async throws {
        let w = ResumeWorld()
        let session = Session(name: "Claude 1", kind: .claude, createdAt: .reference, agentSessionId: "abc-123", lastLaunchedAt: .reference)
        w.load([session])
        #expect(Array(try w.launchArgs(session.id).prefix(4)) == ["--session-id", "abc-123", "--name", "Claude 1"])

        let projects = w.world.agents.claudeConfigDir.appendingPathComponent("projects/-repo")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try "{}\n".write(to: projects.appendingPathComponent("abc-123.jsonl"), atomically: true, encoding: .utf8)
        w.store.relaunch(session.id)
        #expect(Array(try #require(w.world.processes.launches.last).args.prefix(2)) == ["--resume", "abc-123"])
    }

    @Test("Codex encuentra su thread sin robar uno que ya usa otra sesión")
    func codexDiscovery() async throws {
        let w = ResumeWorld()
        let since = Date.reference
        let claimed = Session(name: "Codex 1", kind: .codex, createdAt: since, agentSessionId: "t-de-otra", lastLaunchedAt: since)
        let lost = Session(name: "Codex 2", kind: .codex, createdAt: since, lastLaunchedAt: since) // nunca llegó su thread-id
        try w.codexThread("t-propio", cwd: w.repo.path, modified: since.addingTimeInterval(20))
        try w.codexThread("t-de-otra", cwd: w.repo.path, modified: since.addingTimeInterval(40)) // más nuevo, pero ajeno
        try w.codexThread("t-otra-carpeta", cwd: "/otra/carpeta", modified: since.addingTimeInterval(60))
        w.load([claimed, lost])
        let args = try w.launchArgs(lost.id)
        #expect(args.first == "resume")
        #expect(args.last == "t-propio")
        #expect(w.store.sessionContext(lost.id)?.session.agentSessionId == "t-propio")
    }

    @Test("Gemini usa el id guardado; si no tiene, busca su chat")
    func geminiResume() async throws {
        let w = ResumeWorld()
        let since = Date.reference
        let saved = Session(name: "Gemini 1", kind: .gemini, createdAt: since, agentSessionId: "g-guardado", lastLaunchedAt: since)
        let unknown = Session(name: "Gemini 2", kind: .gemini, createdAt: since, lastLaunchedAt: since)
        try w.geminiChat("g-mas-nuevo", cwd: w.repo.path, modified: since.addingTimeInterval(30))
        w.load([saved, unknown])
        #expect(try w.launchArgs(saved.id) == ["--resume", "g-guardado"])
        #expect(try w.launchArgs(unknown.id) == ["--resume", "g-mas-nuevo"])
    }

    @Test("Lanzar arma el contexto en segundo plano y crea la terminal al volver")
    func backgroundLaunch() async throws {
        let w = ResumeWorld()
        w.world.launchesInBackground = true
        let claude = Session(name: "Claude 1", kind: .claude, createdAt: .reference)
        let shell = Session(name: "Terminal 1", kind: .shell, createdAt: .reference)
        w.load([claude, shell])
        let rt = try #require(w.store.runtimes[claude.id])
        w.store.activate(claude.id)
        w.store.activate(claude.id) // otra vez mientras se arma: no lanza dos veces
        #expect(rt.isLaunching)
        #expect(await waitUntil(timeout: 10) { rt.isRunning })
        #expect(!rt.isLaunching)
        #expect(w.world.processes.launches.count == 1)
        #expect(FileManager.default.fileExists(atPath: w.store.history.markdownURL(claude.id).path))
        #expect(rt.status == .idle)

        // Si la archivás mientras se arma, no se lanza.
        w.store.activate(shell.id)
        w.store.archive(shell.id)
        #expect(await waitUntil(timeout: 10) { w.store.runtimes[shell.id]?.isLaunching == false })
        #expect(w.world.processes.launches.count == 1)
        #expect(w.store.runtimes[shell.id]?.isRunning == false)
    }
}
