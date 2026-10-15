import Foundation
import Testing
@testable import HiveCore

@Suite("Personalizar proyecto")
struct AppearanceFormTests {
    func project(_ icon: ProjectIcon?) -> Project { Project(name: "ecommerce", path: "/e", icon: icon) }

    @Test("Ida y vuelta de cada tipo de ícono", arguments: [
        ProjectIcon.initials, .symbol("cart.fill"), .emoji("🐝"), .emoji("🇦🇷"), .emoji("👨‍👩‍👧‍👦"), .image("/x.png"),
    ])
    func roundTrip(icon: ProjectIcon) {
        #expect(AppearanceForm(project: project(icon), logos: ["/repo/logo.png"]).icon == icon)
    }

    @Test("Cada ícono abre su pestaña", arguments: [
        (ProjectIcon.initials, AppearanceForm.Kind.initials), (.symbol("bolt.fill"), .symbol), (.emoji("🚀"), .emoji), (.image("/a.png"), .logo),
    ] as [(ProjectIcon, AppearanceForm.Kind)])
    func kind(icon: ProjectIcon, kind: AppearanceForm.Kind) {
        #expect(AppearanceForm(project: project(icon)).kind == kind)
    }

    @Test("Sin imagen elegida propone el primer logo del repo, también si los logos llegan después")
    func firstLogo() {
        var form = AppearanceForm(project: project(.initials), logos: ["/repo/a.png", "/repo/b.png"])
        #expect(form.imagePath == "/repo/a.png")
        #expect(form.icon == .initials)            // proponerlo no cambia el ícono
        form.kind = .logo
        #expect(form.icon == .image("/repo/a.png"))

        var late = AppearanceForm(project: project(nil))
        #expect(late.imagePath == nil && late.kind == .initials)
        late.setLogos(["/repo/c.png"])
        #expect(late.imagePath == "/repo/c.png")

        var chosen = AppearanceForm(project: project(.image("/importada.png")), logos: ["/repo/a.png"])
        #expect(chosen.imagePath == "/importada.png")
        #expect(chosen.images == ["/importada.png", "/repo/a.png"])
        chosen.setLogos(["/repo/a.png", "/importada.png"])
        #expect(chosen.images == ["/repo/a.png", "/importada.png"])
    }

    @Test("Un logo sin imagen cae en las iniciales")
    func logoWithoutImage() {
        var form = AppearanceForm(project: project(.initials))
        form.kind = .logo
        #expect(form.icon == .initials)
    }

    @Test("El campo se queda con el último emoji entero y descarta letras", arguments: [
        ("🐝🚀", "🚀"), ("🐝a", "🐝"), ("🇦🇷", "🇦🇷"), ("🐝🇺🇾", "🇺🇾"), ("👨‍👩‍👧‍👦", "👨‍👩‍👧‍👦"), ("🏳️‍🌈", "🏳️‍🌈"),
        ("👍🏽", "👍🏽"), ("🛡️", "🛡️"), ("1️⃣", "1️⃣"), ("⚡️", "⚡️"), ("hola ☕️ chau", "☕️"),
    ])
    func lastEmoji(text: String, expected: String) {
        #expect(AppearanceForm.lastEmoji(text) == expected)
    }

    @Test("Letras, números y símbolos de texto no son emoji", arguments: ["a", "abc", "1", "#", "é", "ñ", "©", " ", ""])
    func notEmoji(text: String) {
        #expect(AppearanceForm.lastEmoji(text) == nil)
    }

    @Test("Escribir «a» no deja .emoji(\"a\")")
    func typingLetters() {
        var form = AppearanceForm(project: project(.emoji("🐝")))
        form.typeEmoji("🐝a")
        #expect(form.emoji == "🐝" && form.icon == .emoji("🐝"))
        form.typeEmoji("a")
        #expect(form.emoji == "")
        #expect(form.icon == .initials)
        form.typeEmoji("🔥")
        #expect(form.icon == .emoji("🔥"))
    }

    @Test("Emoji vacío: al salir del campo vuelve a iniciales y el selector lo muestra")
    func emptyEmoji() {
        var form = AppearanceForm(project: project(.emoji("🐝")))
        form.typeEmoji("")
        #expect(form.kind == .emoji)               // mientras escribís no te cambia la pestaña
        #expect(form.icon == .initials)
        form.finishEmoji()
        #expect(form.kind == .initials && form.icon == .initials)

        var kept = AppearanceForm(project: project(.emoji("🐝")))
        kept.finishEmoji()
        #expect(kept.kind == .emoji)
        var other = AppearanceForm(project: project(.symbol("cart.fill")))
        other.emoji = ""
        other.finishEmoji()
        #expect(other.kind == .symbol)             // solo afecta a la pestaña Emoji
    }

    @Test("Un .emoji guardado con letras se corrige a iniciales")
    func legacyLetterEmoji() {
        #expect(AppearanceForm(project: project(.emoji("a"))).icon == .initials)
    }

    @Test("Etiquetas en castellano")
    func labels() {
        #expect(AppearanceForm.Kind.allCases.map(\.label) == ["Logo", "Iniciales", "Símbolo", "Emoji"])
    }
}
