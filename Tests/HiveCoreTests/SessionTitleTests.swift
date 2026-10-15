import Foundation
import Testing
@testable import HiveCore

@Suite("Nombre automático de las sesiones")
struct SessionTitleTests {
    @Test("Título a partir del primer pedido", arguments: [
        ("Arreglá el login", "Arreglá el login"),
        ("Agregá validación de stock al checkout", "Agregá validación de stock al"),
        ("Revisá @app/Models/Order.php y arreglá el cálculo", "Revisá y arreglá el cálculo"),
        ("/review mirá los tests que fallan", "mirá los tests que fallan"),
        ("/clear", nil),
        ("@app/Http/Kernel.php", nil),
        ("", nil),
        ("   \n\n  ", nil),
        ("¿Por qué falla el test de pagos?", "Por qué falla el test de pagos"), // sin el «?» final, tampoco el «¿»
        ("¿Por qué falla el test de integración de pagos?", "Por qué falla el test de"),
        ("Hacé esto.\nY después esto otro", "Hacé esto"),
        ("@README.md\nDocumentá la API nueva", "Documentá la API nueva"),
        ("Supercalifragilisticoespialidosoextraordinario", "Supercalifragilisticoespialidoso"),
        ("Listo, gracias!!!", "Listo, gracias"),
        ("  Subí   la   versión  ", "Subí la versión"),
    ] as [(String, String?)])
    func title(prompt: String, expected: String?) {
        let title = SessionTitle.from(prompt: prompt)
        #expect(title == expected)
        if let title { #expect(title.count <= SessionTitle.maxLength) }
    }

    @Test("Solo se renombran las sesiones con su nombre automático")
    func canRename() {
        #expect(SessionTitle.canRename(Session(name: "Claude 3", kind: .claude)))
        #expect(SessionTitle.canRename(Session(name: "Codex 12", kind: .codex, autoNamed: true)))
        #expect(!SessionTitle.canRename(Session(name: "Claude 3", kind: .claude, autoNamed: false))) // la renombraste vos
        #expect(!SessionTitle.canRename(Session(name: "Arreglá el login", kind: .claude))) // ya tiene su título
        #expect(!SessionTitle.canRename(Session(name: "Codex 1", kind: .claude)))
        #expect(!SessionTitle.canRename(Session(name: "Claude ", kind: .claude)))
        #expect(!SessionTitle.canRename(Session(name: "Claude 2b", kind: .claude)))
    }
}
