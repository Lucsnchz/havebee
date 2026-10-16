import AppKit
import HiveCore
import SwiftUI

/// Indicador compacto del estado de una sesión (sidebar, pestañas, tarjetas, ⌘K). La forma y el
/// color salen de `StatusStyle`.
struct StatusIndicator: View {
    let status: SessionStatus
    let unseen: Bool
    let kind: SessionKind
    var size: CGFloat = 10
    /// Trabajando en segundo plano (subagentes o un workflow, con el agente principal quieto).
    var background = false

    /// La forma y el color, los mismos que en la píldora de la barra (`StatusPill`).
    var style: StatusStyle { StatusStyle.of(status: status, unseen: unseen, kind: kind, background: background) }

    var body: some View {
        let style = self.style
        ZStack {
            StatusGlyphView(glyph: style.glyph, size: size)
                .id(style.glyph)
                .transition(.scale.combined(with: .opacity))
        }
        .frame(minWidth: size * 1.4)
        .animation(.easeOut(duration: 0.18), value: style.glyph)
        .help(style.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(status: status, unseen: unseen, kind: kind))
    }

    /// «Tu turno, sin ver», «Necesita permiso»…
    static func accessibilityText(status: SessionStatus, unseen: Bool, kind: SessionKind) -> String {
        status.label(for: kind) + (unseen ? ", sin ver" : "")
    }
}

/// Resumen del estado de varias sesiones (para filas de proyecto y rama).
struct AggregateIndicator: View {
    @Environment(AppStore.self) private var store
    let sessions: [Session]

    var body: some View {
        let ring = store.activity(of: sessions).ring
        RingIndicator(ring: ring)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ring.accessibilityText ?? "")
            .accessibilityHidden(ring == .none)
    }
}

/// Píldora con el estado, para la barra de herramientas. El ícono es el mismo de la fila del árbol
/// y de la pestaña: «Tu turno» ya vista es el aro hueco, y el punto lleno queda para la que no viste.
struct StatusPill: View {
    let status: SessionStatus
    let unseen: Bool
    let kind: SessionKind
    var background = false

    var indicator: StatusIndicator { StatusIndicator(status: status, unseen: unseen, kind: kind, background: background) }

    var body: some View {
        HStack(spacing: 6) {
            // Para VoiceOver alcanza con el texto (si no, diría «Trabajando…, sin ver, Trabajando…»).
            indicator
                .accessibilityHidden(true)
            Text(indicator.style.text)
                .font(HiveFont.body)
                .foregroundStyle(.secondary)
                // En la barra con poco lugar no se parte en dos renglones («Trabajando» / «…»).
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Menú "Abrir en…" para la barra de herramientas.
struct OpenInMenu: View {
    let path: String

    var body: some View {
        Menu {
            OpenInItems(path: path)
        } label: {
            Label("Abrir en…", systemImage: "arrow.up.forward.app")
        }
        .help("Abrir la carpeta en otra app")
    }
}

struct Chip: View {
    let text: String
    var help: String = ""

    var body: some View {
        Text(text)
            .font(HiveFont.meta.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(help)
    }
}

/// Muestra la terminal (un NSView que vive en el runtime de la sesión, así el proceso
/// sigue corriendo aunque cambies de sesión).
struct TerminalContainer: NSViewRepresentable {
    let terminal: NSView?

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView()
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        host.show(terminal)
    }
}

final class TerminalHostView: NSView {
    private weak var current: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sin terminal (mientras se abre una sesión), el fondo sigue la apariencia: el color del layer
    /// es fijo y si no quedaría el de cuando se creó. Con terminal, ella se encarga.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if current?.superview !== self { updateBackground() }
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = TerminalTheme.background.cgColor
        }
    }

    func show(_ view: NSView?) {
        // Si es la misma terminal pero otro contenedor se la llevó (el popover de un comando y la
        // esquinita muestran la misma), hay que volver a ponerla acá.
        guard view !== current || (view != nil && view?.superview !== self) else { return }
        if current?.superview === self { current?.removeFromSuperview() }
        current = view
        guard let view else { return }
        view.removeFromSuperview()
        view.autoresizingMask = []
        view.frame = terminalFrame
        addSubview(view)
        needsLayout = true
        // Se mira acá, mientras se procesa el evento que cambió de sesión.
        let clicked = Self.isRecentClick(NSApplication.shared.currentEvent)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window,
                  Self.shouldTakeFocus(from: window.firstResponder, in: window, afterClick: clicked) else { return }
            window.makeFirstResponder(view)
        }
    }

    /// La terminal toma el foco si nadie lo tiene (la ventana o nil) o si lo tenía otra terminal.
    /// Si estás recorriendo el sidebar con las flechas, no te lo saca: si no, la próxima flecha le
    /// llegaría al agente. Un clic (en el sidebar, en una tarjeta o en una pestaña) sí lo da, como
    /// antes, porque es elegir la sesión para escribirle. Nunca se lo saca a un campo de texto.
    static func shouldTakeFocus(from responder: NSResponder?, in window: NSWindow?, afterClick: Bool = false) -> Bool {
        guard let responder else { return true }
        if let window, responder === window { return true }
        if responder is HiveTerminalView { return true }
        return afterClick && !(responder is NSText || responder is NSTextField)
    }

    /// Si el evento es un clic de hace menos de un segundo (no una tecla, ni un clic viejo que
    /// quedó como último evento mientras la terminal cambió por otro motivo).
    static func isRecentClick(_ event: NSEvent?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let event, event.type == .leftMouseDown || event.type == .leftMouseUp else { return false }
        return now - event.timestamp < 1
    }

    // El tamaño se recalcula en cada layout. Antes dependía del autoresizing a partir del primer
    // frame: si la terminal se montaba cuando este contenedor todavía medía 0×0 (al venir desde
    // una rama), el margen daba un rectángulo inválido y la terminal quedaba en negro.
    override func layout() {
        super.layout()
        current?.frame = terminalFrame
    }

    private var terminalFrame: NSRect {
        guard bounds.width > 16, bounds.height > 12 else { return bounds }
        return bounds.insetBy(dx: 8, dy: 6)
    }
}
