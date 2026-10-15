import Foundation
import Testing
@testable import HiveCore

/// Un GitClient que no es GitCLI (como los de los tests de la app): delega en git real salvo la
/// rama por defecto del remoto, que es fija.
private struct FinalRemoteGit: GitClient {
    let base = GitCLI()
    let remoteDefault: String?

    func topLevel(_ dir: String) -> String? { base.topLevel(dir) }
    func currentBranch(_ dir: String) -> String? { base.currentBranch(dir) }
    func localBranches(_ dir: String) -> [String] { base.localBranches(dir) }
    func remoteBranches(_ dir: String) -> [String] { base.remoteBranches(dir) }
    func worktrees(_ dir: String) -> [GitWorktree] { base.worktrees(dir) }
    func status(_ dir: String) -> GitStatus? { base.status(dir) }
    func recentCommits(_ dir: String, limit: Int) -> [GitCommit] { base.recentCommits(dir, limit: limit) }
    func diff(for change: GitChange, staged: Bool, in dir: String) -> FileDiff { base.diff(for: change, staged: staged, in: dir) }
    func isValidBranchName(_ name: String, in dir: String) -> Bool { base.isValidBranchName(name, in: dir) }
    func initRepository(_ dir: String) -> CommandResult { base.initRepository(dir) }
    func createBranch(_ name: String, from base: String, in dir: String) -> CommandResult { self.base.createBranch(name, from: base, in: dir) }
    func addWorktree(at path: String, branch: String, newBranch: Bool, base: String?, in dir: String) -> CommandResult {
        self.base.addWorktree(at: path, branch: branch, newBranch: newBranch, base: base, in: dir)
    }
    func removeWorktree(_ path: String, force: Bool, in dir: String) -> CommandResult { base.removeWorktree(path, force: force, in: dir) }
    func checkout(_ branch: String, in dir: String) -> CommandResult { base.checkout(branch, in: dir) }
    func defaultRemoteBranch(_ dir: String) -> String? { remoteDefault }
}

@Suite("Integración final (núcleo)")
struct IntegracionFinalCoreTests {
    @Test("Con HEAD desacoplado, la rama inicial sale del GitClient aunque no sea el git del sistema")
    func detachedHeadUsesClient() throws {
        let repo = GitRepo(branch: "feature")
        repo.sh("git checkout -q --detach")
        let client = FinalRemoteGit(remoteDefault: "upstream/trunk")
        #expect(MainRepoResolver.originHead(repo.path, git: client) == "upstream/trunk")
        let found = try #require(MainRepoResolver.inspect(repo.path, git: client))
        #expect(found.head == nil)
        #expect(found.initialBranch == "trunk")
        // Sin remoto ni main/master no se inventa una rama «HEAD».
        let none = try #require(MainRepoResolver.inspect(repo.path, git: FinalRemoteGit(remoteDefault: nil)))
        #expect(none.initialBranch == nil)
    }

    @Test("Una copia del transcript que llega tarde no revive el historial de una sesión eliminada")
    func archiveAfterDelete() throws {
        let dir = TempDir()
        let store = HistoryStore(directory: dir.url.appendingPathComponent("history"))
        let transcript = dir.write("claude/projects/-code/c-1.jsonl", AHFixtures.claudeTranscript)
        let kept = UUID()
        let gone = UUID()
        #expect(store.archiveTranscript(sessionId: gone, agent: .claude, path: transcript.path) == 7)
        store.delete(gone)
        #expect(store.isDeleted(gone))
        #expect(!store.isDeleted(kept))
        #expect(!FileManager.default.fileExists(atPath: store.fullURL(gone).path))
        // Llegan tarde la copia y el registro del transcript: no se escribe nada.
        #expect(store.archiveTranscript(sessionId: gone, agent: .claude, path: transcript.path) == 0)
        store.recordTranscript(sessionId: gone, agent: .claude, conversationId: "c-1", path: transcript.path)
        #expect(!FileManager.default.fileExists(atPath: store.fullURL(gone).path))
        #expect(!FileManager.default.fileExists(atPath: store.segmentsURL(gone).path))
        // Las demás sesiones (y la misma id en otra carpeta de historial) siguen igual.
        #expect(store.archiveTranscript(sessionId: kept, agent: .claude, path: transcript.path) == 7)
        let other = HistoryStore(directory: dir.url.appendingPathComponent("otro"))
        #expect(!other.isDeleted(gone))
    }

    @Test("Eliminar mientras se copian transcripts en paralelo no deja copias huérfanas")
    func archiveRacesDelete() throws {
        let dir = TempDir()
        let store = HistoryStore(directory: dir.url.appendingPathComponent("history"))
        let transcript = dir.write("claude/projects/-code/c-1.jsonl", AHFixtures.claudeTranscript)
        let path = transcript.path
        for _ in 0..<5 {
            let id = UUID()
            let done = DispatchGroup()
            for _ in 0..<8 {
                done.enter()
                // Hilos propios (no la cola global): como las tareas en segundo plano de la app.
                Thread {
                    _ = store.archiveTranscript(sessionId: id, agent: .claude, path: path)
                    store.recordTranscript(sessionId: id, agent: .claude, conversationId: "c-1", path: path)
                    done.leave()
                }.start()
            }
            store.delete(id)
            #expect(done.wait(timeout: .now() + 20) == .success)
            #expect(!FileManager.default.fileExists(atPath: store.fullURL(id).path))
            #expect(!FileManager.default.fileExists(atPath: store.segmentsURL(id).path))
        }
    }
}
