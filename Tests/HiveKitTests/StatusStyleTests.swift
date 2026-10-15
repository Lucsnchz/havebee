import AppKit
import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Resuelve un Color de SwiftUI en una apariencia, como sRGB.
@MainActor
private func statusStyleResolved(_ color: Color?, _ appearance: NSAppearance.Name = .darkAqua) -> NSColor? {
    color.map { HiveContrast.resolve(NSColor($0), in: appearance) }
}

@MainActor
private func statusStyleSame(_ a: Color?, _ b: Color?) -> Bool {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        guard let x = statusStyleResolved(a, appearance), let y = statusStyleResolved(b, appearance) else { return a == nil && b == nil }
        if abs(x.redComponent - y.redComponent) > 0.01 || abs(x.greenComponent - y.greenComponent) > 0.01
            || abs(x.blueComponent - y.blueComponent) > 0.01 { return false }
    }
    return true
}

@MainActor
@Suite("Estilo de los estados")
struct StatusStyleTests {
    @Test("Prioridad de una sesión: permiso > sin ver > trabajando")
    func priority() {
        #expect(Activity.Ring.of(status: .attention, unseen: true) == .attention)
        #expect(Activity.Ring.of(status: .attention, unseen: false) == .attention)
        #expect(Activity.Ring.of(status: .working, unseen: true) == .pending)
        #expect(Activity.Ring.of(status: .waiting, unseen: true) == .pending)
        #expect(Activity.Ring.of(status: .working, unseen: false) == .working)
        #expect(Activity.Ring.of(status: .waiting, unseen: false) == .none)
        #expect(Activity.Ring.of(status: .idle, unseen: false) == .none)
        #expect(Activity.Ring.of(status: .dormant, unseen: false) == .none)
        #expect(Activity.Ring.of(status: .exited(1), unseen: false) == .none)
    }

    @Test("La regla de una sesión coincide con la del grupo (Activity.ring)")
    func matchesAggregate() {
        let statuses: [SessionStatus] = [.dormant, .idle, .working, .waiting, .attention, .exited(nil)]
        for status in statuses {
            for unseen in [false, true] {
                var activity = Activity()
                switch Activity.Ring.of(status: status, unseen: unseen) {
                case .attention: activity.attention = 1
                case .pending: activity.pending = 1
                case .working: activity.working = 1
                case .none: break
                }
                #expect(activity.ring == Activity.Ring.of(status: status, unseen: unseen))
            }
        }
        // En un grupo manda lo más urgente.
        #expect(Activity(working: 3, pending: 1, attention: 0).ring == .pending)
        #expect(Activity(working: 3, pending: 2, attention: 1).ring == .attention)
        #expect(Activity(working: 1).ring == .working)
    }

    @Test("Color por estado: naranja, verde, miel o gris")
    func tints() {
        #expect(statusStyleSame(SessionStatus.attention.tint(unseen: false), Theme.attention))
        #expect(statusStyleSame(SessionStatus.waiting.tint(unseen: true), Theme.pending))
        #expect(statusStyleSame(SessionStatus.working.tint(unseen: false), Theme.accent))
        #expect(statusStyleSame(SessionStatus.working.tint(unseen: true), Theme.pending))
        #expect(SessionStatus.waiting.tint(unseen: false) == .secondary)
        #expect(SessionStatus.idle.tint(unseen: false) == .secondary)
        #expect(SessionStatus.dormant.tint(unseen: false) == .secondary)
    }

    @Test("Ring.color y el globito")
    func ringColors() {
        #expect(Activity.Ring.none.color == nil)
        #expect(statusStyleSame(Activity.Ring.working.color, Theme.accent))
        #expect(statusStyleSame(Activity.Ring.pending.color, Theme.pending))
        #expect(statusStyleSame(Activity.Ring.attention.color, Theme.attention))
        #expect(Activity(pending: 2).badgeText == "2")
        #expect(Activity(pending: 2, attention: 1).badgeText == "!")
        #expect(Activity(pending: 1).badgeAccessibilityText == "Una sesión te espera")
        #expect(Activity(pending: 3).badgeAccessibilityText == "3 sesiones te esperan")
        #expect(Activity(pending: 2, attention: 1).badgeAccessibilityText == "Necesita permiso")
        #expect(Activity.Ring.attention.accessibilityText == "Necesita permiso")
        #expect(Activity.Ring.none.accessibilityText == nil)
    }

    @Test("Símbolos y texto para VoiceOver")
    func symbolsAndLabels() {
        #expect(SessionStatus.attention.symbol == "exclamationmark.circle.fill")
        #expect(SessionStatus.exited(0).symbol == "stop.circle")
        #expect(SessionStatus.working.symbol == nil)
        #expect(StatusIndicator.accessibilityText(status: .waiting, unseen: true, kind: .claude) == "Tu turno, sin ver")
        #expect(StatusIndicator.accessibilityText(status: .attention, unseen: false, kind: .codex) == "Necesita permiso")
        #expect(SessionStatus.exited(1).styleKey == SessionStatus.exited(nil).styleKey)
    }

    @Test("Ancho del aro: fino y acotado")
    func ringWidth() {
        #expect(StatusRing.lineWidth(for: 14) == 1.5)
        #expect(StatusRing.lineWidth(for: 20) == 1.5)
        #expect(abs(StatusRing.lineWidth(for: 40) - 2.4) < 0.001)
        #expect(StatusRing.lineWidth(for: 56) == 2.5)
    }

    @Test("Tiempo trabajando y fechas relativas")
    func timeTexts() {
        #expect(RelativeTime.elapsed(0) == "0:00")
        #expect(RelativeTime.elapsed(134) == "2:14")
        #expect(RelativeTime.elapsed(3729) == "1:02:09")
        #expect(RelativeTime.elapsed(-5) == "0:00")
        let now = Date(timeIntervalSince1970: 1_790_942_400)
        #expect(RelativeTime.string(now.addingTimeInterval(-86_400), relativeTo: now)
                == RelativeTime.string(now.addingTimeInterval(-86_400 * 2), relativeTo: now.addingTimeInterval(-86_400)))
    }

    @Test("Descripción de los contadores de git")
    func gitCounters() {
        let one = GitStatus(ahead: 1, changes: [GitChange(code: " M", path: "a.php")])
        #expect(GitCounters.description(one) == "1 archivo con cambios · 1 commit sin pushear")
        let many = GitStatus(behind: 2, changes: [GitChange(code: " M", path: "a"), GitChange(code: "??", path: "b")])
        #expect(GitCounters.description(many) == "2 archivos con cambios · 2 commits sin traer")
        #expect(GitCounters.description(GitStatus()) == "")
    }

    @Test("Ruta abreviada con ~")
    func tildePath() {
        let home = NSHomeDirectory()
        #expect("\(home)/Developer/Hive".tildePath == "~/Developer/Hive")
        #expect("/tmp/otra".tildePath == "/tmp/otra")
    }
}
