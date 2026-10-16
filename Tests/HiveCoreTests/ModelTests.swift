import Foundation
import Testing
@testable import HiveCore

@Suite("Modelo")
struct ModelTests {
    @Test("Cada tipo de sesión sabe qué lanzar")
    func sessionKinds() {
        #expect(SessionKind.claude.binary == "claude")
        #expect(SessionKind.codex.binary == "codex")
        #expect(SessionKind.gemini.binary == "gemini")
        #expect(SessionKind.shell.binary == nil)
        #expect(SessionKind.grok.binary == "grok")
        #expect(SessionKind.allCases.filter(\.isAgent) == [.claude, .codex, .gemini, .grok])
        #expect(SessionKind.allCases.filter(\.reportsConversation) == [.claude, .codex])
        #expect(SessionKind.claude.label == "Claude Code")
        #expect(SessionKind.shell.defaultName == "Terminal")
        #expect(SessionKind.shell.installHint.isEmpty)
        #expect(!SessionKind.gemini.installHint.isEmpty)
    }

    @Test("Iniciales del ícono", arguments: [
        ("ecommerce", "EC"), ("dizeg-kotlin", "DK"), ("mi app", "MA"), ("x", "X"),
        ("emplag-v2", "EV"), ("Hive", "HI"), ("ñandú_feliz", "ÑF"), ("", ""),
    ])
    func initials(name: String, expected: String) {
        #expect(Project.make(name).initials == expected)
    }

    @Test("Carpeta de trabajo según el modo de la rama")
    func directory() {
        let project = Project.make(path: "/repo")
        #expect(project.directory(for: Branch(name: "main", mode: .main)) == "/repo")
        #expect(project.directory(for: Branch(name: "x", mode: .worktree, worktreePath: "/repo.worktrees/x")) == "/repo.worktrees/x")
        // Un worktree sin ruta cae en la carpeta del proyecto.
        #expect(project.directory(for: Branch(name: "y", mode: .worktree)) == "/repo")
    }

    @Test("Color por defecto y proyecto «Terminales»")
    func tintAndScratch() {
        #expect(Project.make().tint == .blue)
        let scratch = Project.scratch(home: "/Users/yo")
        #expect(scratch.isScratch)
        #expect(scratch.path == "/Users/yo")
        #expect(scratch.branches.map(\.name) == ["~"])
        #expect(scratch.tint == .gray)
        #expect(scratch.icon == .symbol("terminal.fill"))
    }

    @Test("Sesiones activas y archivadas")
    func activeAndArchived() {
        let active = Session(name: "A", kind: .claude)
        let archived = Session(name: "B", kind: .codex, archivedAt: .reference)
        let branch = Branch(name: "main", mode: .main, sessions: [archived, active])
        #expect(branch.activeSessions.map(\.name) == ["A"])
        #expect(branch.archivedSessions.map(\.name) == ["B"])
        let project = Project.make(branches: [branch])
        #expect(project.activeSessions.count == 1)
        #expect(project.allSessions.count == 2)
    }

    @Test("La recencia usa la última actividad, después el último arranque, después la creación")
    func recency() {
        var session = Session(name: "A", kind: .claude, createdAt: .reference)
        #expect(session.recency == .reference)
        session.lastLaunchedAt = .reference.addingTimeInterval(10)
        #expect(session.recency == .reference.addingTimeInterval(10))
        session.lastActivityAt = .reference.addingTimeInterval(20)
        #expect(session.recency == .reference.addingTimeInterval(20))
    }

    @Test("El estado guardado ida y vuelta queda igual")
    func stateRoundTrip() throws {
        let session = Session(name: "Claude 1", kind: .claude, createdAt: .reference, agentSessionId: "abc",
                              lastMessage: "Listo", lastActivityAt: .reference, archivedAt: nil, autoNamed: false)
        let branch = Branch(name: "main", mode: .main, sessions: [session], color: .red)
        let project = Project(name: "demo", path: "/repo", branches: [branch], ignoredWorktrees: ["/x"], color: .green,
                              icon: .image("/logo.png"), commands: [ProjectCommand(name: "Dev", command: "npm run dev")])
        let state = HiveState(projects: [project, .scratch(home: "/h")], selection: .session(session.id),
                              expanded: [project.id], lastSessions: [project.id: session.id], mainHeads: [project.id: "main"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HiveState.self, from: encoder.encode(state))
        #expect(decoded == state)
    }

    @Test("Lee estados de versiones anteriores (sin los campos nuevos)")
    func legacyState() throws {
        let json = """
        {"expanded": [], "selection": null, "projects": [{
          "id": "11111111-1111-1111-1111-111111111111", "name": "viejo", "path": "/repo",
          "branches": [{"id": "22222222-2222-2222-2222-222222222222", "name": "main", "mode": "main", "sessions": [
            {"id": "33333333-3333-3333-3333-333333333333", "name": "Terminal 1", "kind": "shell", "createdAt": "2026-10-15T00:00:00Z"}
          ]}]
        }]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(HiveState.self, from: Data(json.utf8))
        let project = try #require(state.projects.first)
        #expect(project.ignoredWorktrees.isEmpty)
        #expect(project.color == nil)
        #expect(project.icon == nil)
        #expect(project.commands.isEmpty)
        #expect(!project.isScratch)
        #expect(state.lastSessions == nil)
        #expect(state.mainHeads == nil)
        let session = try #require(project.branches.first?.sessions.first)
        #expect(session.lastMessage == nil)
        #expect(!session.isArchived)
        #expect(session.autoNamed == nil) // cuenta como automático
    }

    @Test("Íconos de proyecto se guardan y leen", arguments: [
        ProjectIcon.initials, .symbol("cart.fill"), .emoji("🐝"), .image("/a/b.png"),
    ])
    func iconCoding(icon: ProjectIcon) throws {
        let data = try JSONEncoder().encode(icon)
        #expect(try JSONDecoder().decode(ProjectIcon.self, from: data) == icon)
    }

    @Test("El borde de actividad prioriza permiso > pendiente > trabajando")
    func activityRing() {
        #expect(Activity().ring == .none)
        #expect(Activity(working: 2).ring == .working)
        #expect(Activity(working: 2, pending: 1).ring == .pending)
        #expect(Activity(working: 2, pending: 1, attention: 1).ring == .attention)
        #expect(Activity(working: 5, pending: 2, attention: 1).waitingForYou == 3)
    }

    @Test("Etiquetas y propiedades del estado de una sesión")
    func sessionStatus() {
        #expect(SessionStatus.idle.label(for: .claude) == "Lista")
        #expect(SessionStatus.idle.label(for: .shell) == "Abierta")
        #expect(SessionStatus.exited(0).label(for: .claude) == "Terminada")
        #expect(SessionStatus.exited(nil).label(for: .claude) == "Terminada")
        #expect(SessionStatus.exited(2).label(for: .claude) == "Terminada (código 2)")
        #expect(SessionStatus.exited(1).isExited)
        #expect(!SessionStatus.working.isExited)
        #expect(SessionStatus.waiting.needsYou && SessionStatus.attention.needsYou)
        #expect(!SessionStatus.working.needsYou && !SessionStatus.idle.needsYou)
    }

    @Test("Los colores tienen nombre y valores válidos")
    func tintColors() {
        for color in TintColor.allCases {
            #expect(!color.label.isEmpty)
            let (r, g, b) = color.rgb
            #expect((0...1).contains(r) && (0...1).contains(g) && (0...1).contains(b))
        }
        #expect(Set(TintColor.allCases.map(\.label)).count == TintColor.allCases.count)
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Lee objetos, listas, textos, números, booleanos y null")
    func parse() throws {
        let value = try #require(JSONValue.parse(#"{"a": "x", "n": 3, "f": 1.5, "b": true, "l": ["p", 2], "z": null}"#))
        #expect(value["a"] == .string("x"))
        #expect(value["n"] == .number(3))
        #expect(value["f"] == .number(1.5))
        #expect(value["b"] == .bool(true))
        #expect(value["l"] == .array([.string("p"), .number(2)]))
        #expect(value["z"] == .null)
        #expect(value["falta"] == nil)
    }

    @Test("Distingue booleanos de números (NSNumber los mezcla)")
    func boolsAreNotNumbers() throws {
        let value = try #require(JSONValue.parse(#"{"t": true, "uno": 1, "cero": 0, "f": false}"#))
        #expect(value["t"] == .bool(true))
        #expect(value["f"] == .bool(false))
        #expect(value["uno"] == .number(1))
        #expect(value["cero"] == .number(0))
    }

    @Test("JSON inválido devuelve nil")
    func invalid() {
        #expect(JSONValue.parse("{no es json") == nil)
        #expect(JSONValue.parse("") == nil)
    }

    @Test("Ida y vuelta por JSONSerialization")
    func roundTrip() throws {
        let original: JSONValue = ["texto": "hola", "lista": ["a", true], "anidado": ["x": .number(2.5)], "entero": .number(7)]
        let data = try JSONSerialization.data(withJSONObject: original.anyValue)
        #expect(JSONValue.parse(data) == original)
        // Los enteros se escriben sin decimales.
        #expect(String(decoding: data, as: UTF8.self).contains("\"entero\":7"))
    }

    @Test("Accesos tipados")
    func accessors() {
        let value: JSONValue = ["args": ["-y", "pkg"], "env": ["A": "1", "B": .number(2)], "s": "x"]
        #expect(value["args"]?.stringArray == ["-y", "pkg"])
        #expect(value["env"]?.stringDictionary == ["A": "1"])
        #expect(value["s"]?.string == "x")
        #expect(value["s"]?.object == nil)
        #expect(value.string == nil)
        #expect(JSONValue.string("x")["clave"] == nil)
    }
}

@Suite("Estado guardado que no se puede leer")
struct StateStoreUnreadableTests {
    @Test("Un archivo sin permiso de lectura no se toma como vacío ni se aparta")
    func unreadableFile() throws {
        let dir = TempDir()
        let file = dir.write("state.json", "{\"projects\": []}")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let store = StateStore(file: file)
        guard case .unreadable(let reason) = store.load() else {
            Issue.record("Esperaba un estado ilegible")
            return
        }
        #expect(!reason.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Una carpeta en lugar del archivo tampoco se pisa")
    func directoryInsteadOfFile() throws {
        let dir = TempDir()
        let file = dir.subdir("state.json")
        guard case .unreadable = StateStore(file: file).load() else {
            Issue.record("Esperaba un estado ilegible")
            return
        }
    }
}
