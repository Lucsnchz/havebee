import Foundation
import Testing
@testable import HiveCore

@Suite("Enlaces de la terminal (⌘clic)")
struct TerminalLinkTests {
    let dir = TempDir("hive-links")
    var root: String { dir.path }
    var home: String { dir.subdir("home").path }

    init() {
        dir.write("app/Http/Controllers/ProductController.php", "<?php\n")
        dir.write("src/components/Cart.tsx", "export {}\n")
        dir.write("resources/views/welcome.blade.php", "")
        dir.write("Mis Documentos/año.txt", "")
        dir.write("home/notas.md", "")
        dir.write("README.md", "")
    }

    @Test("Ruta relativa con línea, contra la carpeta de la sesión")
    func relativeWithLine() {
        let target = TerminalLink.resolve("app/Http/Controllers/ProductController.php:42", cwd: root, home: home)
        #expect(target == .file(path: root + "/app/Http/Controllers/ProductController.php", line: 42, column: nil))
    }

    @Test("Línea y columna: «:17:3» y «(17,3)»")
    func lineAndColumn() {
        #expect(TerminalLink.resolve("src/components/Cart.tsx:17:3", cwd: root, home: home)
                == .file(path: root + "/src/components/Cart.tsx", line: 17, column: 3))
        #expect(TerminalLink.resolve("src/components/Cart.tsx(17,3)", cwd: root, home: home)
                == .file(path: root + "/src/components/Cart.tsx", line: 17, column: 3))
    }

    @Test("«./», «~/», absolutas, file:// y a/ de los diffs")
    func prefixes() {
        #expect(TerminalLink.resolve("./resources/views/welcome.blade.php", cwd: root, home: home)
                == .file(path: root + "/resources/views/welcome.blade.php", line: nil, column: nil))
        #expect(TerminalLink.resolve("~/notas.md:3", cwd: nil, home: home) == .file(path: home + "/notas.md", line: 3, column: nil))
        #expect(TerminalLink.resolve(root + "/README.md:10", cwd: nil, home: home) == .file(path: root + "/README.md", line: 10, column: nil))
        let fileURL = URL(fileURLWithPath: root + "/Mis Documentos/año.txt").absoluteString
        #expect(TerminalLink.resolve(fileURL, cwd: nil, home: home) == .file(path: root + "/Mis Documentos/año.txt", line: nil, column: nil))
        #expect(TerminalLink.resolve("b/src/components/Cart.tsx", cwd: root, home: home)
                == .file(path: root + "/src/components/Cart.tsx", line: nil, column: nil))
        #expect(TerminalLink.resolve("app/../README.md", cwd: root, home: home) == .file(path: root + "/README.md", line: nil, column: nil))
    }

    @Test("Carpetas")
    func folders() {
        #expect(TerminalLink.resolve("app/Http", cwd: root, home: home) == .folder(path: root + "/app/Http"))
        #expect(TerminalLink.resolve("app/Http/", cwd: root, home: home) == .folder(path: root + "/app/Http"))
    }

    @Test("Lo que no existe, o una relativa sin carpeta, no abre nada")
    func missing() {
        #expect(TerminalLink.resolve("app/NoExiste.php:3", cwd: root, home: home) == nil)
        #expect(TerminalLink.resolve("README.md", cwd: nil, home: home) == nil)
        #expect(TerminalLink.resolve("   ", cwd: root, home: home) == nil)
    }

    @Test("URLs: http, https, www y mailto; la puntuación de alrededor se descarta")
    func urls() {
        #expect(TerminalLink.resolve("https://bevo.test/admin?x=1", cwd: root, home: home) == .url(URL(string: "https://bevo.test/admin?x=1")!))
        #expect(TerminalLink.resolve("(http://localhost:5173/).", cwd: root, home: home) == .url(URL(string: "http://localhost:5173/")!))
        #expect(TerminalLink.resolve("www.laravel.com", cwd: root, home: home) == .url(URL(string: "https://www.laravel.com")!))
        #expect(TerminalLink.resolve("mailto:hola@example.com", cwd: root, home: home) == .url(URL(string: "mailto:hola@example.com")!))
        #expect(TerminalLink.resolve("https://es.wikipedia.org/wiki/Ñandú", cwd: root, home: home) != nil)
    }

    @Test("Comillas y puntuación alrededor de una ruta")
    func punctuation() {
        #expect(TerminalLink.resolve("«README.md».", cwd: root, home: home) == .file(path: root + "/README.md", line: nil, column: nil))
        #expect(TerminalLink.resolve("'src/components/Cart.tsx:17',", cwd: root, home: home)
                == .file(path: root + "/src/components/Cart.tsx", line: 17, column: nil))
    }

    @Test("Con un disco falso: archivo, carpeta o nada")
    func fakeDisk() {
        let kinds: [String: TerminalLink.Kind] = ["/proyecto/app/Models/Order.php": .file, "/proyecto/app": .folder]
        let kind: (String) -> TerminalLink.Kind? = { kinds[$0] }
        #expect(TerminalLink.resolve("app/Models/Order.php:42", cwd: "/proyecto", home: "/Users/x", kind: kind)
                == .file(path: "/proyecto/app/Models/Order.php", line: 42, column: nil))
        #expect(TerminalLink.resolve("app", cwd: "/proyecto", home: "/Users/x", kind: kind) == .folder(path: "/proyecto/app"))
        #expect(TerminalLink.resolve("otra.php", cwd: "/proyecto", home: "/Users/x", kind: kind) == nil)
    }

    @Test("La palabra bajo el clic, en una fila de la terminal")
    func candidate() {
        let line = "  ERROR en app/Models/Order.php:42 (ver https://bevo.test)"
        #expect(TerminalLink.candidate(in: line, at: 14) == "app/Models/Order.php:42")
        #expect(TerminalLink.candidate(in: line, at: 47) == "https://bevo.test")
        #expect(TerminalLink.candidate(in: line, at: 1) == nil)
        #expect(TerminalLink.candidate(in: line, at: 500) == nil)
    }

    @Test("OSC 7: la carpeta del shell")
    func osc7() {
        #expect(TerminalLink.directory(fromOSC7: "file://mac.local/Users/luciano/Mis%20Proyectos") == "/Users/luciano/Mis Proyectos")
        #expect(TerminalLink.directory(fromOSC7: "/Users/luciano") == "/Users/luciano")
        #expect(TerminalLink.directory(fromOSC7: nil) == nil)
        #expect(TerminalLink.directory(fromOSC7: "") == nil)
    }
}
