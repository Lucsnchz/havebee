import Foundation
import Testing
@testable import HiveCore

@Suite("Conservar lo anterior en /clear")
struct ClearPreserverTests {
    let now = Date.reference
    let clear = Array("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8)

    func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    @Test("Sin Enter reciente no toca nada")
    func passthrough() {
        var p = ClearPreserver()
        let input = Array("hola\u{1B}[2J\u{1B}[3J".utf8)
        #expect(p.process(input[...], now: now, rows: 10, cols: 40) == input)
    }

    @Test("Después de un Enter: manda la pantalla al scroll, agrega la divisoria y no borra el scroll")
    func preserves() {
        var p = ClearPreserver()
        p.userPressedEnter(at: now)
        let out = text(p.process(Array("antes".utf8)[...] + clear[...], now: now.addingTimeInterval(1), rows: 3, cols: 40))
        #expect(out.hasPrefix("antes\u{1B}[3;1H\r\n"))           // baja a la última fila
        #expect(out.contains("/clear · "))                      // divisoria
        #expect(out.contains("\r\n\r\n\r\n\u{1B}[H"))           // tantos saltos como filas
        #expect(out.contains("\u{1B}[2J"))                      // el borrado de pantalla queda
        #expect(!out.contains("\u{1B}[3J"))                     // el de scroll no
        #expect(out.hasSuffix("\u{1B}[2J\u{1B}[H"))
    }

    @Test("Un borrado de scroll suelto también se evita")
    func loneScrollbackErase() {
        var p = ClearPreserver()
        p.userPressedEnter(at: now)
        let out = text(p.process(Array("x\u{1B}[3Jy".utf8)[...], now: now, rows: 2, cols: 20))
        #expect(!out.contains("\u{1B}[3J"))
        #expect(out.hasPrefix("x") && out.hasSuffix("y"))
    }

    @Test("Un /clear por Enter, y la ventana vence a los 4 segundos")
    func oncePerEnter() {
        var p = ClearPreserver()
        p.userPressedEnter(at: now)
        _ = p.process(clear[...], now: now, rows: 2, cols: 20)
        #expect(p.process(clear[...], now: now, rows: 2, cols: 20) == clear) // el segundo pasa tal cual

        var late = ClearPreserver()
        late.userPressedEnter(at: now)
        #expect(late.process(clear[...], now: now.addingTimeInterval(ClearPreserver.window + 0.1), rows: 2, cols: 20) == clear)
    }

    @Test("Una secuencia partida entre dos bloques se detecta igual")
    func splitAcrossChunks() {
        var p = ClearPreserver()
        p.userPressedEnter(at: now)
        let first = p.process(Array("antes\u{1B}[2J\u{1B}[".utf8)[...], now: now, rows: 2, cols: 20)
        #expect(text(first) == "antes")                    // retiene el borrado y el pedazo de secuencia
        #expect(p.pending == Array("\u{1B}[2J\u{1B}[".utf8))
        let second = text(p.process(Array("3Jdespués".utf8)[...], now: now, rows: 2, cols: 20))
        #expect(second.contains("/clear · ") && !second.contains("\u{1B}[3J") && second.hasSuffix("después"))
    }

    @Test("Sin Enter, un bloque que termina en ESC se retiene solo hasta completar la secuencia")
    func carriesIncompleteSequence() {
        var p = ClearPreserver()
        #expect(text(p.process(Array("hola\u{1B}".utf8)[...], now: now, rows: 2, cols: 20)) == "hola")
        #expect(text(p.process(Array("[1mnegrita".utf8)[...], now: now, rows: 2, cols: 20)) == "\u{1B}[1mnegrita")
    }

    @Test("Secuencias incompletas", arguments: [
        ("\u{1B}", true), ("\u{1B}[", true), ("\u{1B}[3", true), ("\u{1B}[?25", true),
        ("\u{1B}[3J", false), ("\u{1B}]0;título", false), ("\u{1B}(B", false),
    ])
    func incomplete(sequence: String, expected: Bool) {
        #expect(ClearPreserver.isIncompleteCSI(Array(sequence.utf8)[...]) == expected)
    }

    @Test("La divisoria entra en el ancho de la terminal")
    func dividerWidth() {
        let push = String(decoding: ClearPreserver.pushScreenToScrollback(rows: 4, cols: 30, time: now), as: UTF8.self)
        let line = push.components(separatedBy: "\u{1B}[2m")[1].components(separatedBy: "\u{1B}[0m")[0]
        #expect(line.count <= 29)
        #expect(push.components(separatedBy: "\r\n").count - 1 == 5) // uno para abrir lugar + uno por fila
    }
}

@Suite("Buscador rápido")
struct SwitcherIndexTests {
    let projects: [Project] = {
        let old = Session(name: "Claude 1", kind: .claude, lastActivityAt: Date.reference)
        let recent = Session(name: "Codex pedidos", kind: .codex, lastActivityAt: Date.reference.addingTimeInterval(100))
        let archived = Session(name: "Archivada", kind: .claude, archivedAt: Date.reference)
        var ecommerce = Project(name: "ecommerce", path: "/e", branches: [
            Branch(name: "main", mode: .main, sessions: [old, archived]),
            Branch(name: "SEGURIDAD", mode: .worktree, worktreePath: "/s", sessions: [recent]),
        ])
        ecommerce.commands = [ProjectCommand(name: "Servidor", command: "php artisan serve")]
        var scratch = Project.scratch(home: "/h")
        scratch.branches[0].sessions = [Session(name: "Terminal 1", kind: .shell, createdAt: Date.reference.addingTimeInterval(-100))]
        return [ecommerce, Project(name: "Bevó", path: "/b"), scratch]
    }()

    func titles(_ query: String) -> [String] { SwitcherIndex.search(query, in: projects).map(\.title) }

    @Test("Sin búsqueda: sesiones recientes y después proyectos")
    func emptyQuery() {
        #expect(titles("") == ["Codex pedidos", "Claude 1", "Terminal 1", "ecommerce", "Bevó", "Terminales"])
    }

    @Test("Ordena por prefijo, palabra, contenido y contexto")
    func ranking() {
        #expect(titles("eco").first == "ecommerce")
        #expect(titles("pedidos").first == "Codex pedidos")       // comienzo de palabra
        #expect(titles("seg").first == "SEGURIDAD")
        #expect(titles("seg").contains("Codex pedidos"))          // por el contexto (su rama)
        #expect(titles("serve") == ["Ejecutar Servidor"])
        #expect(titles("zzz").isEmpty)
    }

    @Test("Sin distinguir mayúsculas ni tildes")
    func normalization() {
        #expect(titles("BEVO") == ["Bevó"])
        #expect(titles("bevó") == ["Bevó"])
    }

    @Test("Letras en orden como último recurso")
    func subsequence() {
        #expect(titles("cdxpdd") == ["Codex pedidos"])
    }

    @Test("No muestra archivadas ni la rama interna de «Terminales»")
    func hidden() {
        let all = SwitcherIndex.items(projects)
        #expect(!all.contains { $0.title == "Archivada" })
        #expect(!all.contains { $0.title == "~" })
        #expect(all.first { $0.title == "Terminal 1" }?.subtitle == "Terminales")
        #expect(all.first { $0.title == "Codex pedidos" }?.subtitle == "ecommerce › SEGURIDAD")
    }

    @Test("Respeta el límite de resultados")
    func limit() {
        #expect(SwitcherIndex.search("e", in: projects, limit: 2).count == 2)
    }
}

@Suite("Sugerencias de comandos")
struct CommandSuggestionsTests {
    @Test("Usa el gestor de paquetes según el lockfile", arguments: [
        ("pnpm-lock.yaml", "pnpm dev"), ("yarn.lock", "yarn dev"), ("bun.lockb", "bun run dev"), ("bun.lock", "bun run dev"), (nil, "npm run dev"),
    ] as [(String?, String)])
    func runner(lockfile: String?, expected: String) {
        let dir = TempDir()
        dir.write("package.json", #"{"scripts": {"dev": "vite"}}"#)
        if let lockfile { dir.write(lockfile) }
        #expect(CommandSuggestions.detect(projectPath: dir.path).map(\.command) == [expected])
    }

    @Test("Laravel, composer y Docker; sin repetir lo que ya está")
    func stacks() {
        let dir = TempDir()
        dir.write("package.json", #"{"scripts": {"build": "x", "dev": "y", "otro": "z"}}"#)
        dir.write("artisan")
        dir.write("composer.json", #"{"scripts": {"dev": "x"}, "require-dev": {"laravel/pail": "^1.2"}}"#)
        dir.write("compose.yaml")
        let all = CommandSuggestions.detect(projectPath: dir.path)
        #expect(all.map(\.command) == ["npm run dev", "npm run build", "php artisan serve", "php artisan queue:work",
                                       "php artisan test", "php artisan pail", "composer run dev", "docker compose up"])
        #expect(all.first { $0.command == "php artisan pail" }?.name == "Logs")
        #expect(all.first?.name == "Dev")
        let filtered = CommandSuggestions.detect(projectPath: dir.path, existing: [ProjectCommand(name: "x", command: "php artisan serve")])
        #expect(!filtered.map(\.command).contains("php artisan serve"))
        #expect(CommandSuggestions.detect(projectPath: TempDir().path).isEmpty)
    }
}

@Suite("Logos del repo")
struct LogoFinderTests {
    @Test("Encuentra el logo de una app macOS en Resources, tanto PNG como ICNS")
    func macApp() {
        let dir = TempDir()
        dir.write("Resources/AppIcon.icns")
        let finder = LogoFinder(isUsable: { _ in true })
        #expect(finder.find(in: dir.path).map { URL(fileURLWithPath: $0).lastPathComponent } == ["AppIcon.icns"])
        dir.write("Resources/AppIcon.png")
        #expect(finder.find(in: dir.path).first?.hasSuffix("Resources/AppIcon.png") == true)
    }
    @Test("Prefiere íconos grandes y respeta el validador")
    func priority() {
        let dir = TempDir()
        dir.write("public/favicon.ico")
        dir.write("public/apple-touch-icon.png")
        dir.write("public/logo.png")
        dir.write("public/favicon.png")
        let finder = LogoFinder(isUsable: { !$0.hasSuffix("logo.png") })
        let found = finder.find(in: dir.path).map { ($0 as NSString).lastPathComponent }
        #expect(found == ["apple-touch-icon.png", "favicon.png", "favicon.ico"])
        #expect(LogoFinder(isUsable: { _ in false }).find(in: dir.path).isEmpty)
    }

    @Test("Toma el ícono más grande de un proyecto de Xcode")
    func xcode() {
        let dir = TempDir()
        dir.write("App/Assets.xcassets/AppIcon.appiconset/chico.png", "x")
        dir.write("App/Assets.xcassets/AppIcon.appiconset/grande.png", String(repeating: "x", count: 500))
        dir.write("App/Assets.xcassets/AppIcon.appiconset/Contents.json", "{}")
        let found = LogoFinder(isUsable: { _ in true }).find(in: dir.path)
        #expect(found.map { ($0 as NSString).lastPathComponent } == ["grande.png"])
    }
}

@Suite("Procesos y rutas")
struct ProcessAndPathTests {
    let runner = ProcessCommandRunner()

    @Test("Salida, errores y código de salida")
    func basics() {
        let r = runner.run("/bin/sh", ["-c", "printf hola; printf error >&2; exit 3"])
        #expect(r.stdout == "hola" && r.stderr == "error" && r.status == 3 && !r.ok)
        #expect(r.errorMessage == "error")
        let ok = runner.run("/bin/echo", ["  con espacios  "])
        #expect(ok.ok && ok.output == "con espacios")
        #expect(ok.errorMessage == "con espacios") // sin stderr usa la salida
    }

    @Test("Carpeta y variables de entorno")
    func cwdAndEnvironment() {
        let dir = TempDir()
        let r = runner.run("/bin/sh", ["-c", "pwd; printf \"$HIVE_PRUEBA\""], cwd: dir.path, environment: ["HIVE_PRUEBA": "valor"])
        #expect(r.stdout == "\(dir.path)\nvalor")
    }

    @Test("Un ejecutable que no existe no explota")
    func missingExecutable() {
        let r = runner.run("/no/existe", [])
        #expect(r.status == -1 && !r.stderr.isEmpty)
    }

    @Test("Salidas grandes por stdout y stderr no traban el proceso")
    func largeOutput() {
        let r = runner.run("/bin/sh", ["-c", "head -c 2000000 /dev/zero | tr '\\0' a; head -c 2000000 /dev/zero | tr '\\0' b >&2"])
        #expect(r.ok)
        #expect(r.stdout.count == 2_000_000 && r.stderr.count == 2_000_000)
    }

    @Test("Busca ejecutables en un PATH")
    func whichBinary() {
        #expect(which("sh", path: "/no/existe:/bin") == "/bin/sh")
        #expect(which("no-existe-este-binario", path: "/bin:/usr/bin") == nil)
    }

    @Test("Comillas para sh")
    func quoting() {
        #expect(shellQuote("simple") == "'simple'")
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        let r = runner.run("/bin/sh", ["-c", "printf '%s' " + shellQuote("con 'comillas' y $VARIABLES")])
        #expect(r.stdout == "con 'comillas' y $VARIABLES")
    }

    @Test("Compara rutas con enlaces, barras y ..")
    func paths() {
        #expect(samePath("/tmp", "/private/tmp"))
        #expect(samePath("/usr/bin/", "/usr/bin"))
        #expect(samePath("/usr/lib/../bin", "/usr/bin"))
        #expect(!samePath("/usr/bin", "/usr/lib"))
    }

    @Test("Rutas de datos, con HIVE_HOME para pruebas")
    func hivePaths() {
        let custom = HivePaths.live(environment: ["HIVE_HOME": "/datos/prueba"])
        #expect(custom.root.path == "/datos/prueba")
        #expect(custom.stateFile.path == "/datos/prueba/state.json")
        #expect(custom.eventBin.path == "/datos/prueba/bin/hive-event")
        #expect(custom.historyDir.lastPathComponent == "history")
        let real = HivePaths.live(environment: [:])
        #expect(real.root.path.hasSuffix("Library/Application Support/Hive"))
    }

    @Test("PATH de respaldo: lo típico primero, sin repetir lo heredado")
    func fallbackPath() {
        let path = LoginShell.fallbackPATH(home: "/Users/yo", inherited: "/usr/bin:/mi/bin")
        let dirs = path.split(separator: ":").map(String.init)
        #expect(dirs.first == "/Users/yo/.local/bin")
        #expect(dirs.last == "/mi/bin")
        #expect(dirs.filter { $0 == "/usr/bin" }.count == 1)
    }

    @Test("Lee el PATH de un shell de login y se rinde si tarda demasiado")
    func resolvePath() throws {
        let path = try #require(LoginShell.resolvePATH(shell: "/bin/sh"))
        #expect(path.contains("/usr/bin"))
        let dir = TempDir()
        let slow = dir.write("lento.sh", "#!/bin/sh\nsleep 5\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let start = Date()
        #expect(LoginShell.resolvePATH(shell: slow.path, timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(LoginShell.resolvePATH(shell: "/no/existe") == nil)
        #expect(!LoginShell.path.isEmpty)
        // Lo que imprimen los archivos de arranque del shell no se mezcla con el PATH.
        let chatty = dir.write("charlatan.sh", "#!/bin/sh\necho 'hola desde el .zshrc'\nexec /bin/sh \"$@\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chatty.path)
        #expect(LoginShell.resolvePATH(shell: chatty.path) == path)
    }
}
