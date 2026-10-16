import Foundation
import Testing
@testable import HiveCore

/// Un `.mcp.json` con un error nunca se reescribe: Hive avisa y deja el archivo como estaba.
@Suite("MCP a prueba de errores")
struct MCPSafetyTests {
    /// Le falta la coma entre los dos servidores.
    static let missingComma = """
    {
      "mcpServers": {
        "laravel-boost": {"command": "php", "args": ["artisan", "boost:mcp"]}
        "herd": {"command": "php", "args": ["/Users/yo/herd-mcp.phar"]}
      }
    }
    """

    func bytes(_ dir: TempDir) -> Data? { try? Data(contentsOf: MCPConfig.url(in: dir.path)) }

    @Test("Agregar sobre un JSON inválido lanza el error y deja el archivo igual byte a byte")
    func upsertKeepsBrokenFile() throws {
        let dir = TempDir()
        dir.write(".mcp.json", Self.missingComma)
        let before = try #require(bytes(dir))
        let path = MCPConfig.url(in: dir.path).path
        #expect(throws: MCPConfigError.invalidJSON(path)) {
            try MCPConfig.upsert(MCPServer(name: "context7", config: ["command": "npx"]), dir: dir.path)
        }
        #expect(throws: MCPConfigError.invalidJSON(path)) {
            try MCPConfig.upsert(MCPServer(name: "herd", config: ["command": "php"]), replacing: "laravel-boost", dir: dir.path)
        }
        #expect(bytes(dir) == before)
    }

    @Test("Quitar sobre un JSON inválido lanza el error y no toca el archivo")
    func removeKeepsBrokenFile() throws {
        let dir = TempDir()
        dir.write(".mcp.json", Self.missingComma)
        let before = try #require(bytes(dir))
        #expect(throws: MCPConfigError.self) { try MCPConfig.remove("herd", dir: dir.path) }
        #expect(bytes(dir) == before)
    }

    @Test("loadResult distingue el archivo roto del que no existe; load sigue devolviendo una lista")
    func loadResult() throws {
        let dir = TempDir()
        #expect(try MCPConfig.loadResult(dir: dir.path).get().isEmpty)          // no existe: sin servidores
        dir.write(".mcp.json", Self.missingComma)
        let path = MCPConfig.url(in: dir.path).path
        #expect(throws: MCPConfigError.invalidJSON(path)) { try MCPConfig.loadResult(dir: dir.path).get() }
        #expect(MCPConfig.load(dir: dir.path).isEmpty)                           // el lanzamiento no se entera
        #expect(MCPConfig.load(MCPConfig.url(in: dir.path)).isEmpty)

        dir.write(".mcp.json", #"{"mcpServers": {"b": {"command": "x"}, "A": {"url": "https://a"}}}"#)
        #expect(try MCPConfig.loadResult(dir: dir.path).get().map(\.name) == ["A", "b"])
    }

    @Test("Si mcpServers no es un objeto, tampoco lo reemplaza")
    func serversNotAnObject() throws {
        let dir = TempDir()
        dir.write(".mcp.json", #"{"mcpServers": ["a", "b"]}"#)
        let before = try #require(bytes(dir))
        #expect(throws: MCPConfigError.self) { try MCPConfig.loadResult(dir: dir.path).get() }
        #expect(throws: MCPConfigError.self) { try MCPConfig.upsert(MCPServer(name: "c", config: ["command": "x"]), dir: dir.path) }
        #expect(bytes(dir) == before)
    }

    @Test("mcpServers en null es un archivo válido sin servidores: agregar conserva el resto")
    func serversNull() throws {
        let dir = TempDir()
        dir.write(".mcp.json", #"{"mcpServers": null, "otro": 1}"#)
        #expect(try MCPConfig.loadResult(dir: dir.path).get().isEmpty)
        try MCPConfig.upsert(MCPServer(name: "a", config: ["command": "x"]), dir: dir.path)
        #expect(MCPConfig.load(dir: dir.path).map(\.name) == ["a"])
        #expect(dir.read(".mcp.json")?.contains(#""otro": 1"#) == true)
    }

    @Test("Un archivo que no se puede leer es un error, no una lista vacía")
    func unreadable() throws {
        let dir = TempDir()
        let file = dir.write(".mcp.json", #"{"mcpServers": {"a": {"command": "x"}}}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        guard (try? Data(contentsOf: file)) == nil else { return } // corriendo como root se puede leer igual
        #expect(throws: MCPConfigError.self) { try MCPConfig.loadResult(dir: dir.path).get() }
        #expect(throws: MCPConfigError.self) { try MCPConfig.upsert(MCPServer(name: "b", config: ["command": "y"]), dir: dir.path) }
    }

    @Test("Si el archivo no existe, agregar lo crea y quitar no lo crea")
    func missingFile() throws {
        let dir = TempDir()
        try MCPConfig.remove("nada", dir: dir.path)
        #expect(!FileManager.default.fileExists(atPath: MCPConfig.url(in: dir.path).path))
        try MCPConfig.upsert(MCPServer(name: "a", config: ["command": "x"]), dir: dir.path)
        #expect(try MCPConfig.loadResult(dir: dir.path).get().map(\.name) == ["a"])
        let text = try #require(dir.read(".mcp.json"))
        #expect(text.contains(#""mcpServers": {"#))
    }

    @Test("Quitar un servidor que no está no reescribe el archivo")
    func removeMissingNameKeepsBytes() throws {
        let dir = TempDir()
        dir.write(".mcp.json", #"{"mcpServers":{"a":{"command":"x"}},"z":1}"#)
        let before = try #require(bytes(dir))
        try MCPConfig.remove("otro", dir: dir.path)
        #expect(bytes(dir) == before)
    }

    @Test("Un archivo vacío o sin datos entre comillas se trata como vacío", arguments: ["", "  \n", "{roto", "null", "[]"])
    func emptyLike(content: String) throws {
        let dir = TempDir()
        dir.write(".mcp.json", content)
        #expect(try MCPConfig.loadResult(dir: dir.path).get().isEmpty)
        try MCPConfig.upsert(MCPServer(name: "a", config: ["command": "x"]), dir: dir.path)
        #expect(MCPConfig.load(dir: dir.path).map(\.name) == ["a"])
    }

    @Test("Un archivo con servidores escritos sin comillas o con comillas simples tampoco se reescribe", arguments: [
        "{ mcpServers: { herd: { command: php } } }",
        "{'mcpServers': {'herd': {'command': 'php'}}}",
    ])
    func looseSyntaxKeepsFile(content: String) throws {
        let dir = TempDir()
        dir.write(".mcp.json", content)
        let before = try #require(bytes(dir))
        #expect(throws: MCPConfigError.self) { try MCPConfig.loadResult(dir: dir.path).get() }
        #expect(throws: MCPConfigError.self) { try MCPConfig.upsert(MCPServer(name: "a", config: ["command": "x"]), dir: dir.path) }
        #expect(throws: MCPConfigError.self) { try MCPConfig.remove("herd", dir: dir.path) }
        #expect(bytes(dir) == before)
    }

    @Test("El error se explica en castellano y nombra el archivo")
    func message() {
        let error = MCPConfigError.invalidJSON("/code/x/.mcp.json")
        #expect(error.path == "/code/x/.mcp.json")
        let text = error.localizedDescription
        #expect(text.hasPrefix(".mcp.json tiene un error de sintaxis"))
        #expect(text.contains("/code/x/.mcp.json"))
    }
}
