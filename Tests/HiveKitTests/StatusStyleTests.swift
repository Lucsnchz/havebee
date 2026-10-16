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
        // Una sesión se pinta como su ícono: si trabaja, miel (el «sin ver» lo cuenta su grupo).
        #expect(statusStyleSame(SessionStatus.working.tint(unseen: true), Theme.accent))
        #expect(SessionStatus.waiting.tint(unseen: false) == .secondary)
        #expect(SessionStatus.idle.tint(unseen: false) == .secondary)
        #expect(SessionStatus.dormant.tint(unseen: false) == .secondary)
    }

    @Test("Una sola forma, color y texto por estado (sidebar, pestañas, tarjetas, ⌘K e Inicio)")
    func singleSourceOfTruth() {
        func check(_ status: SessionStatus, unseen: Bool, _ glyph: StatusGlyph, _ color: Color?, _ text: String,
                   kind: SessionKind = .claude, sourceLocation: SourceLocation = #_sourceLocation) {
            let style = StatusStyle.of(status: status, unseen: unseen, kind: kind)
            #expect(style.glyph == glyph, sourceLocation: sourceLocation)
            #expect(statusStyleSame(style.color, color), sourceLocation: sourceLocation)
            #expect(style.text == text, sourceLocation: sourceLocation)
        }
        check(.attention, unseen: true, .attention, Theme.attention, "Necesita permiso")
        check(.attention, unseen: false, .attention, Theme.attention, "Necesita permiso")
        check(.waiting, unseen: true, .pending, Theme.pending, "Tu turno")
        check(.waiting, unseen: false, .seen, nil, "Tu turno")
        check(.working, unseen: false, .working, Theme.accent, "Trabajando…")
        check(.working, unseen: true, .working, Theme.accent, "Trabajando…")
        check(.idle, unseen: false, .idle, nil, "Lista")
        check(.idle, unseen: false, .idle, nil, "Abierta", kind: .shell)
        check(.exited(0), unseen: false, .exited, nil, "Terminada")
        check(.dormant, unseen: false, .none, nil, "Dormida")

        // Los grupos usan las mismas formas y los colores del anillo del riel.
        let rings: [(Activity.Ring, StatusGlyph, Color?, String)] = [
            (.attention, .attention, Theme.attention, "Necesita permiso"), (.pending, .pending, Theme.pending, "Te espera"),
            (.working, .working, Theme.accent, "Trabajando"), (.none, .none, nil, ""),
        ]
        for (ring, glyph, color, text) in rings {
            let style = StatusStyle.of(ring: ring)
            #expect(style.glyph == glyph && style.text == text, "\(ring)")
            #expect(statusStyleSame(style.color, color), "\(ring)")
            #expect(statusStyleSame(style.color, ring.color), "\(ring)")
        }
        // Una sesión sola destacada se dibuja igual que el grupo que destaca por ella.
        for status in [SessionStatus.attention, .waiting, .working] {
            let ring = Activity.Ring.of(status: status, unseen: status == .waiting)
            #expect(StatusStyle.of(status: status, unseen: status == .waiting, kind: .codex).glyph == StatusStyle.of(ring: ring).glyph)
        }
        // El Inicio titula cada grupo con el ícono de su estado (y un reloj en «Recientes»).
        let sessions = [Session(name: "a", kind: .claude), Session(name: "b", kind: .codex), Session(name: "c", kind: .claude),
                        Session(name: "d", kind: .shell)]
        let statuses: [UUID: SessionStatus] = [sessions[0].id: .attention, sessions[1].id: .waiting, sessions[2].id: .working]
        let project = Project(name: "p", path: "/tmp/p", branches: [Branch(name: "main", mode: .main, sessions: sessions)])
        let groups = HomeSessionGroups.build(projects: [project], status: { statuses[$0] })
        #expect(groups.map { $0.title } == ["Necesitan permiso", "Tu turno", "Trabajando", "Recientes"])
        #expect(groups.map { $0.ring } == [.attention, .pending, .working, .none])
    }

    @Test("Muestrario: los estados en el sidebar, la tarjeta y ⌘K se ven iguales")
    func swatches() async {
        let statuses: [(SessionStatus, Bool)] = [(.attention, false), (.waiting, true), (.waiting, false), (.working, false),
                                                 (.idle, false), (.exited(0), false)]
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 12) {
                    StatusIndicator(status: item.0, unseen: item.1, kind: .claude)
                    StatusPill(status: item.0, kind: .claude)
                    Text(StatusStyle.of(status: item.0, unseen: item.1, kind: .claude).text)
                        .foregroundStyle(StatusStyle.of(status: item.0, unseen: item.1, kind: .claude).color ?? .secondary)
                }
            }
            HStack(spacing: 12) {
                ForEach([Activity.Ring.attention, .pending, .working], id: \.self) { RingIndicator(ring: $0, size: 12) }
            }
        }
        .padding(16)
        let defaults = SnapshotDefaults()
        let reps = await Snapshot.render(view, size: CGSize(width: 360, height: 270), name: "estados-muestrario", defaults: defaults.defaults)
        #expect(reps.count == 2)
        for rep in reps { #expect(Snapshot.distinctColors(rep) > 3) }
    }

    @Test("Ring.color: el aro del riel, el globito y los íconos de estado tienen el mismo color")
    func ringColors() {
        #expect(Activity.Ring.none.color == nil)
        #expect(statusStyleSame(Activity.Ring.working.color, Theme.accent))
        #expect(statusStyleSame(Activity.Ring.pending.color, Theme.pending))
        #expect(statusStyleSame(Activity.Ring.attention.color, Theme.attention))
        // StatusRing y ActivityBadge toman el color de StatusStyle.of(ring:); el texto del globito
        // está en ActivityBadgeTests.
        for ring in [Activity.Ring.none, .working, .pending, .attention] {
            #expect(statusStyleSame(StatusStyle.of(ring: ring).color, ring.color))
        }
        // Una sesión sola y el grupo que la contiene se pintan igual.
        #expect(statusStyleSame(StatusStyle.of(status: .attention, unseen: false, kind: .claude).color, Activity.Ring.attention.color))
        #expect(statusStyleSame(StatusStyle.of(status: .waiting, unseen: true, kind: .claude).color, Activity.Ring.pending.color))
        #expect(statusStyleSame(StatusStyle.of(status: .working, unseen: false, kind: .claude).color, Activity.Ring.working.color))
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
