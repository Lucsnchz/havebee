import Foundation
import Testing
@testable import HiveCore

@Suite("Editor de MCP")
struct MCPServerFormTests {
    @Test("La línea de comando va y vuelve igual", arguments: [
        ["--config={\"a\":1}"], ["it's"], [""], ["con espacio"], ["a\\b"], ["C:\\tools\\x.exe"],
        ["dice \"hola\" y 'chau'"], ["\\\"", "'", "\""], ["tab\there"], ["línea\nnueva"], ["", "", "x"],
        ["php", "artisan", "boost:mcp"], ["/ruta con espacios/herd.phar", "--flag=1"], ["ñandú", "🐝"],
    ] as [[String]])
    func roundTrip(words: [String]) {
        let line = MCPConfig.joinCommandLine(words)
        #expect(MCPConfig.splitCommandLine(line) == words, "\(line)")
    }

    @Test("Las palabras simples quedan sin comillas y las raras se citan")
    func readableQuoting() {
        #expect(MCPConfig.joinCommandLine(["php", "artisan", "boost:mcp"]) == "php artisan boost:mcp")
        #expect(MCPConfig.joinCommandLine(["--config={\"a\":1}"]) == #"'--config={"a":1}'"#)
        #expect(MCPConfig.joinCommandLine(["it's"]) == #""it's""#)
        #expect(MCPConfig.joinCommandLine([""]) == #""""#)
        #expect(MCPConfig.joinCommandLine([]) == "")
    }

    @Test("La barra invertida escapa espacios y comillas, y fuera de eso queda tal cual", arguments: [
        (#"a\ b"#, ["a b"]), (#"\"hola\""#, ["\"hola\""]), (#""di \"hola\"""#, ["di \"hola\""]),
        (#"C:\tools\x.exe"#, [#"C:\tools\x.exe"#]), (#"'sin\escape'"#, [#"sin\escape"#]), (#"a\\b"#, [#"a\b"#]),
        (#"fin\"#, [#"fin\"#]),
    ] as [(String, [String])])
    func backslash(line: String, words: [String]) {
        #expect(MCPConfig.splitCommandLine(line) == words)
    }

    @Test("Abrir y guardar sin cambios deja el servidor idéntico", arguments: [
        MCPServer(name: "json", config: ["command": "npx", "args": ["--config={\"a\":1}"]]),
        MCPServer(name: "apostrofo", config: ["command": "node", "args": ["it's"]]),
        MCPServer(name: "vacio", config: ["command": "x", "args": [""]]),
        MCPServer(name: "args-vacios", config: ["command": "x", "args": []]),
        MCPServer(name: "env", config: ["command": "x", "env": ["A": " con espacios ", "B": "a=b"], "cwd": "/tmp"]),
        MCPServer(name: "numeros", config: ["command": "x", "args": ["a", .number(1)], "timeout": .number(30)]),
        MCPServer(name: "sse", config: ["type": "sse", "url": "https://x/sse", "headers": ["Authorization": "Bearer 1"]]),
        MCPServer(name: "sin-type", config: ["url": "https://x/mcp"]),
        MCPServer(name: "gemini", config: ["httpUrl": "https://x/mcp", "trust": true]),
        MCPServer(name: "stdio", config: ["type": "stdio", "command": "php", "args": ["artisan", "boost:mcp"]]),
    ])
    func unchanged(server: MCPServer) {
        #expect(MCPServerForm(server: server).apply(to: server) == server)
    }

    @Test("Cambiar la URL de un sse lo deja en sse y conserva los encabezados")
    func editSSE() {
        let sse = MCPServer(name: "docs", config: ["type": "sse", "url": "https://x/sse", "headers": ["A": "1"]])
        var form = MCPServerForm(server: sse)
        #expect(form.remote)
        form.url = "  https://y/sse "
        let saved = form.apply(to: sse)
        #expect(saved.config == ["type": "sse", "url": "https://y/sse", "headers": ["A": "1"]])

        let gemini = MCPServer(name: "g", config: ["httpUrl": "https://x"])
        var other = MCPServerForm(server: gemini)
        other.url = "https://z"
        #expect(other.apply(to: gemini).config == ["httpUrl": "https://z"])
    }

    @Test("Editar el comando conserva los campos desconocidos y respeta las comillas")
    func editCommand() {
        let server = MCPServer(name: "x", config: ["command": "php", "args": ["a"], "timeout": .number(30), "env": ["K": "V"]])
        var form = MCPServerForm(server: server)
        #expect(form.commandLine == "php a")
        form.commandLine = #"node "/ruta con espacios/x.js" --name='it'\''s'"#
        let saved = form.apply(to: server)
        #expect(saved.command == "node")
        #expect(saved.config["timeout"] == .number(30))
        #expect(saved.env == ["K": "V"])
        form.commandLine = "solo"
        #expect(form.apply(to: server).config["args"] == nil)
    }

    @Test("Pasar de local a remoto limpia comando, argumentos y entorno")
    func localToRemote() {
        let local = MCPServer(name: "x", config: ["type": "stdio", "command": "php", "args": ["a"], "env": ["K": "V"], "cwd": "/c", "timeout": .number(5)])
        var form = MCPServerForm(server: local)
        form.remote = true
        form.url = "https://x/mcp"
        #expect(form.apply(to: local).config == ["type": "http", "url": "https://x/mcp", "timeout": .number(5)])
    }

    @Test("Pasar de remoto a local limpia URL, tipo y encabezados")
    func remoteToLocal() {
        let remote = MCPServer(name: "x", config: ["type": "sse", "url": "https://x", "headers": ["A": "1"], "timeout": .number(5)])
        var form = MCPServerForm(server: remote)
        form.remote = false
        form.commandLine = "npx -y paquete"
        form.environment = "A=1"
        #expect(form.apply(to: remote).config == ["command": "npx", "args": ["-y", "paquete"], "env": ["A": "1"], "timeout": .number(5)])
    }

    @Test("Un servidor nuevo")
    func new() {
        let local = MCPServerForm(name: "  boost ", commandLine: "php artisan boost:mcp", environment: "\nAPP_ENV=local\n")
        #expect(local.apply(to: nil) == MCPServer(name: "boost", config: ["command": "php", "args": ["artisan", "boost:mcp"], "env": ["APP_ENV": "local"]]))
        let remote = MCPServerForm(name: "docs", remote: true, url: "https://docs/mcp")
        #expect(remote.apply(to: nil).config == ["type": "http", "url": "https://docs/mcp"])
    }

    @Test("Cuándo se puede guardar")
    func canSave() {
        #expect(!MCPServerForm().canSave)
        #expect(!MCPServerForm(name: "x").canSave)
        #expect(!MCPServerForm(name: "  ", commandLine: "php").canSave)
        #expect(!MCPServerForm(name: "x", commandLine: #""""#).canSave)
        #expect(MCPServerForm(name: "x", commandLine: "php").canSave)
        #expect(!MCPServerForm(name: "x", remote: true, url: "ejemplo.com").canSave)
        #expect(!MCPServerForm(name: "x", remote: true, url: "ftp://ejemplo.com").canSave)
        #expect(MCPServerForm(name: "x", remote: true, url: " https://ejemplo.com/mcp ").canSave)
        #expect(MCPServerForm(name: "x", remote: true, url: "http://localhost:8080/mcp").canSave)
    }

    @Test("Nombre repetido")
    func nameTaken() {
        let form = MCPServerForm(name: "boost ")
        #expect(form.nameIsTaken(by: ["boost", "herd"], editing: nil))
        #expect(!form.nameIsTaken(by: ["boost", "herd"], editing: "boost"))
        #expect(form.nameIsTaken(by: ["boost", "herd"], editing: "herd"))
        #expect(!form.nameIsTaken(by: ["herd"], editing: nil))
    }

    @Test("Entorno: = dentro del valor, líneas vacías, comentarios y líneas sin clave")
    func environment() {
        let text = """

        DB_URL=mysql://u:p@h/db?x=1
          ESPACIOS  =  valor con espacios
        # comentario
        =sin clave
        SIN_IGUAL
        VACIA=
        export DESDE_ENV=1
        """
        #expect(MCPServerForm.parseEnvironment(text) == [
            "DB_URL": "mysql://u:p@h/db?x=1", "ESPACIOS": "valor con espacios", "VACIA": "", "DESDE_ENV": "1",
        ])
        #expect(MCPServerForm.environmentText(["B": "2", "A": "1=1"]) == "A=1=1\nB=2")
        #expect(MCPServerForm.parseEnvironment(MCPServerForm.environmentText(["B": "2", "A": "1=1"])) == ["B": "2", "A": "1=1"])
    }

    @Test("Vaciar el entorno lo quita del archivo")
    func clearEnvironment() {
        let server = MCPServer(name: "x", config: ["command": "x", "env": ["K": "V"]])
        var form = MCPServerForm(server: server)
        #expect(form.environment == "K=V")
        form.environment = ""
        #expect(form.apply(to: server).config == ["command": "x"])
    }
}
