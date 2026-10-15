import Foundation
import Testing
@testable import HiveCore

@Suite("Rutas para pegar en la terminal")
struct ShellQuotingTests {
    @Test("Una ruta común queda igual")
    func plain() {
        #expect(ShellQuoting.quote("/Users/luciano/Developer/app/Models/Order.php") == "/Users/luciano/Developer/app/Models/Order.php")
        #expect(ShellQuoting.quote("captura-2026_10.png") == "captura-2026_10.png")
    }

    @Test("Espacios, ñ y tildes van entre comillas simples")
    func spacesAndAccents() {
        #expect(ShellQuoting.quote("/Users/luciano/Mis Documentos/año.txt") == "'/Users/luciano/Mis Documentos/año.txt'")
        #expect(ShellQuoting.quote("/tmp/canción") == "'/tmp/canción'")
    }

    @Test("Una comilla simple adentro se escapa con '\\''")
    func singleQuote() {
        #expect(ShellQuoting.quote("/tmp/it's here") == "'/tmp/it'\\''s here'")
    }

    @Test("Lo que el shell expande también va entre comillas")
    func shellSpecials() {
        for path in ["/tmp/$HOME", "/tmp/*.png", "~/archivo", "/tmp/a;b", "/tmp/a&b", "/tmp/(1)", "/tmp/a\"b", "=ls", ""] {
            #expect(ShellQuoting.quote(path).hasPrefix("'"), "\(path) debería ir entre comillas")
        }
    }

    @Test("Varias rutas: separadas por espacios y con un espacio al final")
    func pasteText() {
        #expect(ShellQuoting.pasteText(for: ["/tmp/a.png", "/tmp/con espacio.png"]) == "/tmp/a.png '/tmp/con espacio.png' ")
        #expect(ShellQuoting.pasteText(for: []) == "")
    }

    @Test("Lo escapado vuelve a dar la ruta original en un shell de verdad")
    func roundTrip() {
        let paths = ["/tmp/Mis Documentos/año ñandú.txt", "/tmp/it's", "/tmp/$HOME y *", "/tmp/comillas \"dobles\""]
        for path in paths {
            let result = ProcessCommandRunner().run("/bin/sh", ["-c", "printf '%s' \(ShellQuoting.quote(path))"], cwd: "/tmp", environment: [:])
            #expect(result.stdout == path)
        }
    }
}
