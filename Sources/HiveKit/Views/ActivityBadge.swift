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
        let waiting = activity.waitingForYou
        guard waiting > 0 else { return nil }
        let permission = activity.attention == 1 ? "una necesita permiso" : "\(activity.attention) necesitan permiso"
        if activity.attention == waiting {
            return waiting == 1 ? "Una sesión necesita permiso" : "\(waiting) sesiones necesitan permiso"
        }
        let total = waiting == 1 ? "Una sesión te espera" : "\(waiting) sesiones te esperan"
        return activity.attention > 0 ? "\(total), \(permission)" : total
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
