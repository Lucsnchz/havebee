import Foundation
import Testing
@testable import HiveCore

@Suite("Nombre automático de las sesiones")
struct SessionTitleTests {
    @Test("Título a partir del primer pedido", arguments: [
        ("Arreglá el login", "Arreglá el login"),
        ("Agregá validación de stock al checkout", "Agregá validación de stock"), // sin el «al» colgado
        ("Revisá @app/Models/Order.php y arreglá el cálculo", "Revisá y arreglá el cálculo"),
        ("/review mirá los tests que fallan", "mirá los tests que fallan"),
        ("/clear", nil),
        ("@app/Http/Kernel.php", nil),
        ("", nil),
        ("   \n\n  ", nil),
        ("¿Por qué falla el test de pagos?", "Por qué falla el test de pagos"), // sin el «?» final, tampoco el «¿»
        ("¿Por qué falla el test de integración de pagos?", "Por qué falla el test"),
        ("Hacé esto.\nY después esto otro", "Hacé esto"),
        ("@README.md\nDocumentá la API nueva", "Documentá la API nueva"),
        ("Supercalifragilisticoespialidosoextraordinario", "Supercalifragilisticoespialidoso"),
        ("Listo, gracias!!!", "Listo, gracias"),
        ("  Subí   la   versión  ", "Subí la versión"),
        // Sin palabras colgadas al cortar: preposiciones, artículos y conjunciones, también varias seguidas.
        ("Migrá los pedidos viejos a la tabla nueva de envíos", "Migrá los pedidos viejos"),
        ("Revisá el carrito de compras, y también los tests", "Revisá el carrito de compras"),
        ("Arreglá el login de usuarios Y el registro", "Arreglá el login de usuarios"),
        ("Add stock validation to the checkout and the cart", "Add stock validation"),
        ("Mirá cómo quedó el @app/Models/Order.php", "Mirá cómo quedó"), // la @ruta del final también es un corte
        // Sin corte, el título queda como lo escribiste.
        ("Probá con el", "Probá con el"),
        ("Arreglá el login de la", "Arreglá el login de la"),
        // Si todo son palabras de unión, no se borra nada.
        ("de la de la de la de la de la de la de la", "de la de la de la de la de la de"),
    ] as [(String, String?)])
    func title(prompt: String, expected: String?) {
        let title = SessionTitle.from(prompt: prompt)
        #expect(title == expected)
        if let title { #expect(title.count <= SessionTitle.maxLength) }
    }

    @Test("Las palabras colgadas se sacan del final, sin distinguir mayúsculas")
    func danglingWords() {
        #expect(SessionTitle.trimmingDanglingWords("Agregá validación de stock al") == "Agregá validación de stock")
        #expect(SessionTitle.trimmingDanglingWords("Subí la versión, y") == "Subí la versión")
        #expect(SessionTitle.trimmingDanglingWords("Fix the bug in the") == "Fix the bug")
        #expect(SessionTitle.trimmingDanglingWords("Arreglá el login DEL") == "Arreglá el login")
        #expect(SessionTitle.trimmingDanglingWords("Arreglá el login") == "Arreglá el login")
        #expect(SessionTitle.trimmingDanglingWords("de la") == "de la")
        #expect(SessionTitle.trimmingDanglingWords("Probá sí") == "Probá sí") // «sí» con tilde no es «si»
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
