import Foundation
import HiveCore
import Testing
@testable import HiveKit

@MainActor
@Suite("Globito de «te esperan»")
struct ActivityBadgeTests {
    @Test("El globito dice lo mismo en el sidebar y en el riel: «!» delante si algo pide permiso")
    func badgeText() {
        #expect(ActivityBadge.text(Activity()) == nil)
        #expect(ActivityBadge.text(Activity(working: 3)) == nil)
        #expect(ActivityBadge.text(Activity(pending: 2)) == "2")
        #expect(ActivityBadge.text(Activity(pending: 1, attention: 1)) == "!2")
        #expect(ActivityBadge.text(Activity(attention: 1)) == "!1")
        #expect(ActivityBadge.accessibilityText(Activity()) == nil)
        #expect(ActivityBadge.accessibilityText(Activity(pending: 1)) == "Una sesión te espera")
        #expect(ActivityBadge.accessibilityText(Activity(pending: 3)) == "3 sesiones te esperan")
        #expect(ActivityBadge.accessibilityText(Activity(attention: 1)) == "Una sesión necesita permiso")
        #expect(ActivityBadge.accessibilityText(Activity(attention: 2)) == "2 sesiones necesitan permiso")
        #expect(ActivityBadge.accessibilityText(Activity(pending: 2, attention: 1)) == "3 sesiones te esperan, una necesita permiso")
        #expect(ActivityBadge.accessibilityText(Activity(pending: 1, attention: 2)) == "3 sesiones te esperan, 2 necesitan permiso")
    }
}
