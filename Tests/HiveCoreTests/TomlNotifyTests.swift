import Foundation
import Testing
@testable import HiveCore

@Suite("TOML: el notify de Codex en cualquier formato")
struct TomlNotifyTests {
    func notify(_ text: String) -> TOML.StringArrayLookup {
        TOML.topLevelStringArray("notify", in: text)
    }

    @Test("Comillas dobles y simples", arguments: [
        (#"notify = ["/usr/local/bin/notifier", "turn"]"#, ["/usr/local/bin/notifier", "turn"]),
        ("notify = ['/usr/local/bin/notifier', 'turn']", ["/usr/local/bin/notifier", "turn"]),
        (#"notify = ['C:\sin\escapes', "con \"comillas\" y \\ barra"]"#, [#"C:\sin\escapes"#, #"con "comillas" y \ barra"#]),
        (#"notify = ["tilde \u00e1 y tab\tok"]"#, ["tilde á y tab\tok"]),
        ("notify=[]", []),
    ])
    func quotes(text: String, expected: [String]) {
        #expect(notify(text) == .found(expected))
    }

    @Test("En varias líneas, con coma final y comentarios")
    func multiline() {
        #expect(notify("""
        # Mi config
        model = "gpt-5.1-codex"   # con comentario
        notify = [
            "/usr/local/bin/notifier",  # el programa
            # una línea comentada en el medio
            "turn",
        ]
        """) == .found(["/usr/local/bin/notifier", "turn"]))
        #expect(notify("notify = [\r\n  'a',\r\n  'b'\r\n]\r\n") == .found(["a", "b"]))
        // Un # dentro de un texto no es un comentario.
        #expect(notify(#"notify = ["canal#1", 'y # este']"#) == .found(["canal#1", "y # este"]))
    }

    @Test("Saltea los valores de otras claves, aunque ocupen varias líneas")
    func skipsOtherValues() {
        #expect(notify(#"""
        instructions = """
        notify = ["no", "es este"]
        """
        literal = '''
        tampoco ['x']
        '''
        lista = [[1, 2], {a = "]"}, "["]
        tabla = { notify = ["adentro"], otra = 'b' }
        "clave rara" = 1
        fecha = 2026-10-12T10:00:00Z
        notify = ["/apps/Otro App/bin", "turn-ended"]
        """#) == .found(["/apps/Otro App/bin", "turn-ended"]))
    }

    @Test("Solo cuenta el de nivel superior")
    func topLevelOnly() {
        #expect(notify("[tabla]\nnotify = [\"x\"]") == .missing)
        #expect(notify("[[perfiles]]\nnotify = [\"x\"]") == .missing)
        #expect(notify("notifyx = [\"x\"]") == .missing)
        #expect(notify("otro.notify = [\"x\"]") == .missing)
        #expect(notify("") == .missing)
        // El primero gana si está repetido.
        #expect(notify("notify = ['a']\nnotify = ['b']") == .found(["a"]))
    }

    @Test("Una clave que existe pero no se puede leer", arguments: [
        #"notify = "/un/solo/texto""#,
        #"notify = ["sin cerrar""#,
        #"notify = ["a" "b"]"#,
        "notify = [1, 2]",
        #"notify = ["escape \q raro"]"#,
        "notify = ['texto\ncortado']",
        "notify =",
    ])
    func unreadable(text: String) {
        #expect(notify(text) == .unreadable)
    }

    @Test("Un config.toml roto no cuelga la lectura", .timeLimit(.minutes(1)), arguments: [
        "otra = [1}\nnotify = ['x']",
        "otra = {a = 1]\nnotify = ['x']",
        "otra = [{a = [1}]\nnotify = ['x']",
        "otra = [1,\nnotify = ['x']",
    ])
    func brokenConfig(text: String) {
        // Lo que viene después de un valor roto ya no se puede ubicar: no está, pero tampoco se cuelga.
        #expect(notify(text) == .missing)
    }

    @Test("El notify del usuario con comillas simples o en varias líneas se sigue encadenando")
    func chained() {
        let config = """
        notify = [
          '/Applications/Sky.app/Contents/MacOS/SkyComputerUseClient',
          'turn-ended',
        ]
        """
        let existing = CodexNotify.existing(inConfig: config)
        #expect(existing == ["/Applications/Sky.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"])
        #expect(CodexNotify.override(eventBin: "/h", existing: existing)
            == #"notify=["/h", "codex", "/Applications/Sky.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]"#)
    }

    @Test("codexNotifyStatus: sin archivo, legible e ilegible")
    func status() {
        let codex = TempDir("hive-codex")
        let storage = AgentStorage(claudeConfigDir: codex.url, codexHome: codex.url, geminiHome: codex.url)
        #expect(storage.codexNotifyStatus().command == nil && !storage.codexNotifyStatus().unreadable)
        codex.write("config.toml", "model = 'x'\n")
        #expect(storage.codexNotifyStatus().command == nil && !storage.codexNotifyStatus().unreadable)
        codex.write("config.toml", "notify = ['/x', 'y',]\n")
        #expect(storage.codexNotifyStatus().command == ["/x", "y"] && !storage.codexNotifyStatus().unreadable)
        #expect(storage.codexExistingNotify() == ["/x", "y"])
        codex.write("config.toml", "notify = '/x'\n")
        #expect(storage.codexNotifyStatus().command == nil && storage.codexNotifyStatus().unreadable)
        #expect(storage.codexExistingNotify() == nil)
    }
}
