import HiveCore
import SwiftUI

// Única fuente de verdad de cómo se ve cada estado: naranja = necesita permiso, verde = te espera
// y no la viste, miel = trabajando, sin color = nada que destacar. Prioridad en un grupo: permiso >
// sin ver > trabajando. Todas las vistas (Inicio, ⌘K, tarjetas, sidebar, pestañas y riel) dibujan
// los estados con `StatusStyle` y `StatusGlyphView`: nadie elige su propio ícono ni su color.

/// La forma con la que se dibuja un estado.
enum StatusGlyph: Equatable, CaseIterable {
    /// «!» naranja que rebota al aparecer: necesita permiso.
    case attention
    /// Punto verde lleno: te espera y no la viste.
    case pending
    /// Aro verde hueco: tu turno, pero ya la viste.
    case seen
    /// Arco miel que gira: trabajando.
    case working
    /// Punto gris: abierta, sin actividad del agente.
    case idle
    /// ⏹ gris: terminó.
    case exited
    /// Nada (dormida, o un grupo sin nada que destacar).
    case none
}

/// Ícono, color y texto de un estado.
struct StatusStyle: Equatable {
    let glyph: StatusGlyph
    /// Color para destacar el texto y el borde; nil si no hay nada que destacar (va en gris).
    let color: Color?
    let text: String

    /// El estado de una sesión. El ícono sale del estado; «sin ver» solo cambia el de «tu turno»
    /// (punto lleno o aro hueco). Una sesión que trabaja se ve trabajando aunque tenga algo sin ver:
    /// eso lo cuenta el grupo (`of(ring:)`).
    static func of(status: SessionStatus, unseen: Bool, kind: SessionKind) -> StatusStyle {
        let text = status.label(for: kind)
        switch status {
        case .attention: return StatusStyle(glyph: .attention, color: Theme.attention, text: text)
        case .waiting: return unseen ? StatusStyle(glyph: .pending, color: Theme.pending, text: text)
                                     : StatusStyle(glyph: .seen, color: nil, text: text)
        case .working: return StatusStyle(glyph: .working, color: Theme.accent, text: text)
        case .idle: return StatusStyle(glyph: .idle, color: nil, text: text)
        case .exited: return StatusStyle(glyph: .exited, color: nil, text: text)
        case .dormant: return StatusStyle(glyph: .none, color: nil, text: text)
        }
    }

    /// Lo que se destaca de un grupo de sesiones (proyecto, rama, títulos del Inicio).
    static func of(ring: Activity.Ring) -> StatusStyle {
        switch ring {
        case .attention: StatusStyle(glyph: .attention, color: ring.color, text: ring.accessibilityText ?? "")
        case .pending: StatusStyle(glyph: .pending, color: ring.color, text: ring.accessibilityText ?? "")
        case .working: StatusStyle(glyph: .working, color: ring.color, text: ring.accessibilityText ?? "")
        case .none: StatusStyle(glyph: .none, color: nil, text: "")
        }
    }
}

extension Activity.Ring {
    /// Lo que hay que destacar de una sesión sola (misma prioridad que `Activity.ring`).
    static func of(status: SessionStatus, unseen: Bool) -> Activity.Ring {
        if status == .attention { return .attention }
        if unseen { return .pending }
        if status == .working { return .working }
        return .none
    }

    /// Color del estado destacado, o nil si no hay nada que destacar. Es el del anillo del riel.
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

extension SessionStatus {
    /// Color del estado de una sesión (gris si no hay nada que destacar). Es el de `StatusStyle`.
    func tint(unseen: Bool) -> Color {
        StatusStyle.of(status: self, unseen: unseen, kind: .claude).color ?? .secondary
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

/// Dibuja un `StatusGlyph`. `size` es el diámetro del arco de «trabajando»; lo demás se escala
/// a partir de ahí para que todos los estados pesen lo mismo.
struct StatusGlyphView: View {
    let glyph: StatusGlyph
    var size: CGFloat = 10

    var body: some View {
        switch glyph {
        case .attention:
            AttentionSymbol(size: size * 1.25)
        case .pending:
            PendingDot(size: size * 0.8)
        case .seen:
            Circle()
                .strokeBorder(Theme.pending.opacity(0.7), lineWidth: max(1.2, size * 0.15))
                .frame(width: size * 0.8, height: size * 0.8)
                .accessibilityHidden(true)
        case .working:
            WorkingGlyph(size: size, lineWidth: max(1.4, size * 0.18))
        case .idle:
            Circle()
                .fill(.secondary.opacity(0.5))
                .frame(width: size * 0.6, height: size * 0.6)
                .accessibilityHidden(true)
        case .exited:
            Image(systemName: SessionStatus.exited(nil).symbol ?? "stop.circle")
                .font(.system(size: size * 1.2))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }
}

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
    var size: CGFloat = 12.5
    @State private var bounce = false

    var body: some View {
        Image(systemName: SessionStatus.attention.symbol ?? "exclamationmark.circle.fill")
            .font(.system(size: size))
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
            .shadow(color: Theme.pending.opacity(0.5), radius: size * 0.3)
            .accessibilityHidden(true)
    }
}

/// Indicador del estado destacado de un grupo (o de una sesión): permiso, sin ver o trabajando.
struct RingIndicator: View {
    let ring: Activity.Ring
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            StatusGlyphView(glyph: StatusStyle.of(ring: ring).glyph, size: size)
                .id(ring)
                .transition(.scale.combined(with: .opacity))
        }
        .animation(.easeOut(duration: 0.18), value: ring)
    }
}
