import AppKit
import HiveCore
import SwiftUI

/// Indicador compacto del estado de una sesión.
struct StatusIndicator: View {
    let status: SessionStatus
    let unseen: Bool
    let kind: SessionKind

    var body: some View {
        ZStack {
            switch status {
            case .working:
                WorkingGlyph()
                    .transition(.scale.combined(with: .opacity))
            case .attention:
                AttentionSymbol()
                    .transition(.scale.combined(with: .opacity))
            case .waiting:
                Group {
                    if unseen {
                        PendingDot()
                    } else {
                        Circle().strokeBorder(Theme.pending.opacity(0.7), lineWidth: 1.5).frame(width: 8, height: 8)
                    }
                }
                .transition(.scale.combined(with: .opacity))
            case .idle:
                Circle().fill(.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    .transition(.opacity)
            case .exited:
                Image(systemName: status.symbol ?? "stop.circle")
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            case .dormant:
                EmptyView()
            }
        }
        .frame(minWidth: 14)
        .animation(.easeOut(duration: 0.18), value: status.styleKey)
        .animation(.easeOut(duration: 0.18), value: unseen)
        .help(status.label(for: kind))
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

/// Píldora con el estado, para la barra de herramientas.
struct StatusPill: View {
    let status: SessionStatus
    let kind: SessionKind

    var body: some View {
        HStack(spacing: 6) {
            StatusIndicator(status: status, unseen: true, kind: kind)
            Text(status.label(for: kind))
                .font(HiveFont.body)
                .foregroundStyle(.secondary)
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
        layer?.backgroundColor = TerminalTheme.background.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ view: NSView?) {
        guard view !== current else { return }
        current?.removeFromSuperview()
        current = view
        guard let view else { return }
        view.removeFromSuperview()
        view.autoresizingMask = []
        view.frame = terminalFrame
        addSubview(view)
        needsLayout = true
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window,
                  Self.shouldTakeFocus(from: window.firstResponder, in: window) else { return }
            window.makeFirstResponder(view)
        }
    }

    /// La terminal toma el foco solo si nadie lo tiene (la ventana o nil) o si lo tenía otra
    /// terminal. Si estás en el sidebar o escribiendo en un campo, no te lo saca: si no, la
    /// próxima flecha le llegaría al agente.
    static func shouldTakeFocus(from responder: NSResponder?, in window: NSWindow?) -> Bool {
        guard let responder else { return true }
        if let window, responder === window { return true }
        return responder is HiveTerminalView
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
