import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Globito de «te esperan»")
struct ActivityBadgeTests {
    @Test("El globito dice lo mismo en el sidebar y en el riel: naranja con «!» cuenta solo los permisos")
    func badgeText() {
        #expect(ActivityBadge.text(Activity()) == nil)
        #expect(ActivityBadge.text(Activity(working: 3)) == nil)
        #expect(ActivityBadge.text(Activity(pending: 2)) == "2")
        // Uno pide permiso y otro te espera: «!1», como «Necesitan permiso 1» en el Inicio (no «!2»).
        #expect(ActivityBadge.text(Activity(pending: 1, attention: 1)) == "!1")
        #expect(ActivityBadge.text(Activity(attention: 1)) == "!1")
        #expect(ActivityBadge.text(Activity(pending: 3, attention: 2)) == "!2")
        // El desglose completo queda en el globo de ayuda y en VoiceOver.
        #expect(ActivityBadge.accessibilityText(Activity(pending: 1, attention: 1)) == "2 sesiones te esperan, una necesita permiso")
        #expect(ActivityBadge.accessibilityText(Activity()) == nil)
        #expect(ActivityBadge.accessibilityText(Activity(pending: 1)) == "Una sesión te espera")
        #expect(ActivityBadge.accessibilityText(Activity(pending: 3)) == "3 sesiones te esperan")
        #expect(ActivityBadge.accessibilityText(Activity(attention: 1)) == "Una sesión necesita permiso")
        #expect(ActivityBadge.accessibilityText(Activity(attention: 2)) == "2 sesiones necesitan permiso")
        #expect(ActivityBadge.accessibilityText(Activity(pending: 2, attention: 1)) == "3 sesiones te esperan, una necesita permiso")
        #expect(ActivityBadge.accessibilityText(Activity(pending: 1, attention: 2)) == "3 sesiones te esperan, 2 necesitan permiso")
    }

    @Test("Después de un nombre va en minúscula: «Inicio, una sesión te espera»")
    func homeText() {
        #expect(ActivityBadge.accessibilityPhrase(Activity(attention: 1)) == "una sesión necesita permiso")
        #expect(ActivityBadge.homeAccessibilityText(Activity()) == "Inicio")
        #expect(ActivityBadge.homeAccessibilityText(Activity(working: 2)) == "Inicio")
        #expect(ActivityBadge.homeAccessibilityText(Activity(pending: 1)) == "Inicio, una sesión te espera")
        #expect(ActivityBadge.homeAccessibilityText(Activity(pending: 1, attention: 1)) == "Inicio, 2 sesiones te esperan, una necesita permiso")
    }

    @Test("El riel y el árbol dicen lo mismo de un proyecto, permiso incluido (no solo el color del aro)")
    func projectText() {
        let pinned = Project(name: "ecommerce", path: "/e", pinned: true)
        let permission = Activity(working: 1, attention: 1)
        // Una sola sesión pide permiso: se dice una vez, no «una te espera, una necesita permiso».
        #expect(RailItem.accessibilityText(project: pinned, activity: permission) == "ecommerce, fijado, una sesión necesita permiso")
        #expect(ActivityBadge.projectAccessibilityLabel("Proyecto ecommerce", pinned: true, activity: permission, isActive: true)
            == "Proyecto ecommerce, fijado, una sesión necesita permiso")
        #expect(ActivityBadge.projectAccessibilityValue(permission) == "una sesión trabajando")
        #expect(ActivityBadge.projectAccessibilityValue(Activity(pending: 2, attention: 2)) == "")
        #expect(ActivityBadge.projectAccessibilityValue(Activity(working: 2)) == "2 sesiones trabajando")
        #expect(ActivityBadge.projectAccessibilityValue(Activity(pending: 3)) == "")

        let bevo = Project(name: "bevo", path: "/b")
        #expect(RailItem.accessibilityText(project: bevo, activity: Activity(pending: 2, attention: 1))
            == "bevo, 3 sesiones te esperan, una necesita permiso")
        #expect(RailItem.accessibilityText(project: bevo, activity: Activity(attention: 2)) == "bevo, 2 sesiones necesitan permiso")
        #expect(RailItem.accessibilityText(project: bevo, activity: Activity(working: 2)) == "bevo")
        #expect(RailItem.accessibilityText(project: bevo, activity: Activity(), isActive: false) == "bevo, sin actividad hoy")
    }

    @Test("Atenuado: sin actividad hoy, salvo el proyecto abierto o el que tiene el puntero (riel y árbol)")
    func dimRule() {
        #expect(DimmedProject.dims(isActive: false, isCurrent: false, hovering: false))
        #expect(!DimmedProject.dims(isActive: true, isCurrent: false, hovering: false))
        #expect(!DimmedProject.dims(isActive: false, isCurrent: true, hovering: false))
        #expect(!DimmedProject.dims(isActive: false, isCurrent: false, hovering: true))
        #expect(DimmedProject.opacity(for: .dark) >= 0.5 && DimmedProject.opacity(for: .light) >= 0.5)
    }
}
