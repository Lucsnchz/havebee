import HiveCore
import SwiftUI

// Única fuente de verdad de cómo se ve cada estado: naranja = necesita permiso, verde = te espera
// y no la viste, miel = trabajando. Prioridad: permiso > sin ver > trabajando.

extension Activity.Ring {
    /// Lo que hay que destacar de una sesión sola (misma prioridad que `Activity.ring`).
    static func of(status: SessionStatus, unseen: Bool) -> Activity.Ring {
        if status == .attention { return .attention }
        if unseen { return .pending }
        if status == .working { return .working }
        return .none
    }

    /// Color del estado destacado, o nil si no hay nada que destacar.
    var color: Color? {
        switch self {
        case .none: nil
        case .working: Theme.accent
        case .pending: Theme.pending
        case .attention: Theme.attention
        }
    }

    /// Texto para VoiceOver.
    var accessibilityText: String? {
        switch self {
        case .none: nil
        case .working: "Trabajando"
        case .pending: "Te espera"
        case .attention: "Necesita permiso"
        }
    }
}

extension Activity {
    /// Texto del globito: «!» si algo pide permiso, si no la cantidad que te espera.
    var badgeText: String { attention > 0 ? "!" : "\(waitingForYou)" }

    /// Lo mismo para VoiceOver: «Necesita permiso», «Una sesión te espera», «3 sesiones te esperan».
    var badgeAccessibilityText: String {
        if attention > 0 { return "Necesita permiso" }
        return waitingForYou == 1 ? "Una sesión te espera" : "\(waitingForYou) sesiones te esperan"
    }
}

extension SessionStatus {
    /// Color del estado (gris si no hay nada que destacar).
    func tint(unseen: Bool) -> Color {
        Activity.Ring.of(status: self, unseen: unseen).color ?? .secondary
    }

    /// Símbolo del estado, si se dibuja con uno.
    var symbol: String? {
        switch self {
        case .attention: "exclamationmark.circle.fill"
        case .exited: "stop.circle"
        default: nil
        }
    }

    /// Para comparar estados sin el código de salida (animaciones y transiciones).
    var styleKey: Int {
        switch self {
        case .dormant: 0
        case .idle: 1
        case .working: 2
        case .waiting: 3
        case .attention: 4
        case .exited: 5
        }
    }
}

// MARK: - Piezas

/// Arco miel que gira: «trabajando». Lo anima Core Animation (no redibuja la vista en cada cuadro);
/// con «Reducir movimiento» queda un aro fijo.
struct WorkingGlyph: View {
    var size: CGFloat = 10
    var lineWidth: CGFloat = 1.8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: reduceMotion ? 1 : 0.7)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = !reduceMotion }
            .onChange(of: reduceMotion) { _, reduce in spinning = !reduce }
            .accessibilityHidden(true)
    }
}

/// Ícono de «necesita permiso», que rebota al aparecer.
struct AttentionSymbol: View {
    @State private var bounce = false

    var body: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(Theme.attention)
            .symbolEffect(.bounce, value: bounce)
            .onAppear { bounce.toggle() }
            .accessibilityHidden(true)
    }
}

/// Puntito verde de «te espera».
struct PendingDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Theme.pending)
            .frame(width: size, height: size)
            .shadow(color: Theme.pending.opacity(0.5), radius: 2.5)
            .accessibilityHidden(true)
    }
}

/// Indicador del estado destacado de un grupo (o de una sesión): permiso, sin ver o trabajando.
struct RingIndicator: View {
    let ring: Activity.Ring

    var body: some View {
        ZStack {
            switch ring {
            case .attention: AttentionSymbol().transition(.scale.combined(with: .opacity))
            case .pending: PendingDot().transition(.scale.combined(with: .opacity))
            case .working: WorkingGlyph().transition(.scale.combined(with: .opacity))
            case .none: EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.18), value: ring)
    }
}
