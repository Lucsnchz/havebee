import Foundation
import Testing
@testable import HiveCore

@Suite("Lanzamiento: pantalla alternativa, Gemini, Android y uso de Claude")
struct LaunchPlannerExtraTests {
    let paths = HivePaths(root: URL(fileURLWithPath: "/datos/Hive"))

    func context(_ kind: SessionKind, agentId: String? = nil, home: String = "/Users/yo",
                 configure: (inout LaunchContext) -> Void = { _ in }) -> LaunchContext {
        var ctx = LaunchContext(
            session: Session(name: "Sesión", kind: kind, agentSessionId: agentId),
            project: Project(name: "app", path: "/code/app"), branch: Branch(name: "main", mode: .main),
            directory: "/code/app", path: "/bin:/usr/bin", inheritedEnvironment: ["HOME": home],
            paths: paths, historyHint: false, newAgentId: "nuevo")
        configure(&ctx)
        return ctx
    }

    static let altScreen = #"tui.alternate_screen="never""#

    @Test("Codex arranca sin pantalla alternativa si el ajuste está prendido, también al reanudar")
    func codexAltScreen() throws {
        let fresh = LaunchPlanner.plan(context(.codex))
        let index = try #require(fresh.args.firstIndex(of: Self.altScreen))
        #expect(fresh.args[index - 1] == "-c")

        let resumed = LaunchPlanner.plan(context(.codex, agentId: "t-1"))
        #expect(resumed.args.first == "resume")
        #expect(resumed.args.contains(Self.altScreen))
        #expect(resumed.args.last == "t-1") // las opciones van antes del thread

        let off = LaunchPlanner.plan(context(.codex, agentId: "t-1") { $0.claudeInline = false })
        #expect(!off.args.contains(Self.altScreen))
        // Claude sigue con su variable de entorno, no con argumentos.
        #expect(!LaunchPlanner.plan(context(.claude)).args.contains(Self.altScreen))
    }

    @Test("Gemini: el chat guardado le gana al encontrado en la carpeta")
    func geminiSavedWins() {
        let saved = LaunchPlanner.plan(context(.gemini, agentId: "g-propio") { $0.discoveredAgentId = "g-ajeno" })
        #expect(saved.args == ["--resume", "g-propio"])
        #expect(saved.agentSessionId == "g-propio")
        let discovered = LaunchPlanner.plan(context(.gemini) { $0.discoveredAgentId = "g-nuevo" })
        #expect(discovered.args == ["--resume", "g-nuevo"])
    }

    @Test("Con el SDK de Android instalado, define ANDROID_HOME y suma platform-tools al PATH")
    func androidHome() {
        let home = TempDir("hive-home")
        let without = SessionEnvironment.base(inherited: ["HOME": home.path], directory: "/d", path: "/bin")
        #expect(without["ANDROID_HOME"] == nil)
        #expect(without["PATH"] == "/bin")

        _ = home.subdir("Library/Android/sdk/platform-tools")
        let sdk = home.url.appendingPathComponent("Library/Android/sdk").path
        let with = SessionEnvironment.base(inherited: ["HOME": home.path], directory: "/d", path: "/bin:/usr/bin")
        #expect(with["ANDROID_HOME"] == sdk)
        #expect(with["PATH"] == "/bin:/usr/bin:\(sdk)/platform-tools")

        // Si ya lo tenías definido, se respeta tal cual.
        let mine = SessionEnvironment.base(inherited: ["HOME": home.path, "ANDROID_HOME": "/otro/sdk"], directory: "/d", path: "/bin")
        #expect(mine["ANDROID_HOME"] == "/otro/sdk")
        #expect(mine["PATH"] == "/bin")
        // Las sesiones también lo reciben.
        let plan = LaunchPlanner.plan(context(.shell, home: home.path))
        #expect(plan.environment["ANDROID_HOME"] == sdk)
        // Sin HOME no se busca nada.
        #expect(SessionEnvironment.base(inherited: [:], directory: "/d", path: "/bin")["ANDROID_HOME"] == nil)
    }

    @Test("claudeUsage elige los ajustes con statusLine y encadena el del usuario")
    func claudeUsage() throws {
        func settingsArg(_ plan: LaunchPlan) throws -> String {
            let index = try #require(plan.args.firstIndex(of: "--settings"))
            return plan.args[index + 1]
        }
        let off = LaunchPlanner.plan(context(.claude) { $0.claudeUserStatusLine = "~/.claude/statusline.sh" })
        #expect(try settingsArg(off) == "/datos/Hive/claude-settings.json")
        #expect(off.environment["HIVE_USER_STATUSLINE"] == nil)

        let on = LaunchPlanner.plan(context(.claude) { $0.claudeUsage = true })
        #expect(try settingsArg(on) == "/datos/Hive/claude-settings-usage.json")
        #expect(on.environment["HIVE_USER_STATUSLINE"] == nil)

        let chained = LaunchPlanner.plan(context(.claude) {
            $0.claudeUsage = true
            $0.claudeUserStatusLine = "  npx ccstatusline  "
        })
        #expect(chained.environment["HIVE_USER_STATUSLINE"] == "npx ccstatusline")
        let blank = LaunchPlanner.plan(context(.claude) { $0.claudeUsage = true; $0.claudeUserStatusLine = " " })
        #expect(blank.environment["HIVE_USER_STATUSLINE"] == nil)
        // Un HIVE_USER_STATUSLINE heredado no se cuela.
        let inherited = LaunchPlanner.plan(context(.claude) { $0.inheritedEnvironment["HIVE_USER_STATUSLINE"] = "viejo" })
        #expect(inherited.environment["HIVE_USER_STATUSLINE"] == nil)
    }

    @Test("LaunchContextBuilder: con el uso de Claude prendido busca el statusLine del usuario; apagado, ni lo mira")
    func builderClaudeUsage() {
        let root = TempDir("hive-builder")
        let claudeDir = root.subdir("claude")
        root.write("claude/settings.json", #"{"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}"#)
        let repo = root.subdir("repo").path
        let agents = AgentStorage(claudeConfigDir: claudeDir, codexHome: root.subdir("codex"), geminiHome: root.subdir("gemini"))
        func build(_ kind: SessionKind, usage: Bool) -> LaunchContext {
            LaunchContextBuilder(session: Session(name: "S", kind: kind), project: Project(name: "app", path: repo),
                                 branch: Branch(name: "main", mode: .main), directory: repo, path: "/bin",
                                 inheritedEnvironment: [:], paths: HivePaths(root: root.url.appendingPathComponent("Hive")),
                                 agents: agents, historyHint: false, claudeUsage: usage).build()
        }
        let on = build(.claude, usage: true)
        #expect(on.claudeUsage)
        #expect(on.claudeUserStatusLine == "~/.claude/statusline.sh")
        #expect(LaunchPlanner.plan(on).environment["HIVE_USER_STATUSLINE"] == "~/.claude/statusline.sh")
        let off = build(.claude, usage: false)
        #expect(!off.claudeUsage && off.claudeUserStatusLine == nil)
        // Solo Claude tiene statusLine.
        #expect(build(.codex, usage: true).claudeUserStatusLine == nil)
        // Por defecto, apagado.
        #expect(!LaunchContextBuilder(session: Session(name: "S", kind: .claude), project: Project(name: "app", path: repo),
                                      branch: Branch(name: "main", mode: .main), directory: repo, path: "/bin",
                                      inheritedEnvironment: [:], paths: HivePaths(root: root.url), agents: agents).claudeUsage)
    }
}
