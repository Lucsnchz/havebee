import AppKit
import HiveCore
import SwiftUI

/// Globito con cuántas sesiones te esperan, el mismo en el Inicio y en los proyectos, en el riel y
/// en el árbol: «!» delante si alguna necesita permiso (así no depende solo del color) y el fondo
/// naranja de permiso o verde de «te espera».
struct ActivityBadge: View {
    let activity: Activity
    /// Con un borde del color de la ventana, para despegarlo del ícono sobre el que se apoya.
    var outlined = false

    /// «!2» si alguna de las dos pide permiso, «2» si solo te esperan; nil si no hay nada.
    static func text(_ activity: Activity) -> String? {
        guard activity.waitingForYou > 0 else { return nil }
        return (activity.attention > 0 ? "!" : "") + "\(activity.waitingForYou)"
    }

    /// Lo mismo para VoiceOver y para el globo de ayuda: «Una sesión necesita permiso»,
    /// «3 sesiones te esperan, una necesita permiso»…
    static func accessibilityText(_ activity: Activity) -> String? {
        accessibilityPhrase(activity).map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// Lo mismo, en minúscula, para decirlo después de un nombre: «Inicio, una sesión te espera».
    static func accessibilityPhrase(_ activity: Activity) -> String? {
        let waiting = activity.waitingForYou
        guard waiting > 0 else { return nil }
        let permission = activity.attention == 1 ? "una necesita permiso" : "\(activity.attention) necesitan permiso"
        if activity.attention == waiting {
            return waiting == 1 ? "una sesión necesita permiso" : "\(waiting) sesiones necesitan permiso"
        }
        let total = waiting == 1 ? "una sesión te espera" : "\(waiting) sesiones te esperan"
        return activity.attention > 0 ? "\(total), \(permission)" : total
    }

    /// Lo que dice VoiceOver del Inicio, en el árbol y en el riel: «Inicio, 2 sesiones te esperan,
    /// una necesita permiso».
    static func homeAccessibilityText(_ activity: Activity) -> String {
        accessibilityPhrase(activity).map { "Inicio, \($0)" } ?? "Inicio"
    }

    /// Lo que dice VoiceOver de un proyecto, igual en el riel y en el árbol: el nombre, si está
    /// fijado y cuántas sesiones te esperan («ecommerce, fijado, 2 sesiones te esperan»), o
    /// «bevo, sin actividad hoy». El detalle va en `projectAccessibilityValue`.
    static func projectAccessibilityLabel(_ name: String, pinned: Bool, activity: Activity, isActive: Bool) -> String {
        var parts = [name]
        if pinned { parts.append("fijado") }
        let waiting = activity.waitingForYou
        if waiting > 0 {
            parts.append(waiting == 1 ? "una sesión te espera" : "\(waiting) sesiones te esperan")
        } else if !isActive && activity.working == 0 {
            parts.append("sin actividad hoy")
        }
        return parts.joined(separator: ", ")
    }

    /// El detalle que VoiceOver lee después: cuántas piden permiso (lo que el globito dice con el
    /// «!», así no depende del color del aro) y cuántas están trabajando. Vacío si no hay nada.
    static func projectAccessibilityValue(_ activity: Activity) -> String {
        var parts: [String] = []
        if activity.attention > 0 {
            parts.append(activity.attention == 1 ? "una necesita permiso" : "\(activity.attention) necesitan permiso")
        }
        if activity.working > 0 {
            parts.append(activity.working == 1 ? "una sesión trabajando" : "\(activity.working) sesiones trabajando")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        if let text = Self.text(activity) {
            Text(text)
                .font(.system(size: 10, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 4.5)
                .frame(minWidth: 16, minHeight: 16)
                .background(activity.ring.color ?? Theme.pending, in: Capsule())
                .overlay {
                    if outlined { Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2).padding(-2) }
                }
                .fixedSize()
                .help(Self.accessibilityText(activity) ?? "")
                .accessibilityLabel(Self.accessibilityText(activity) ?? "")
                .transition(.scale.combined(with: .opacity))
        }
    }
}
