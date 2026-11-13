import AppKit
import SwiftUI

/// Lo que gira mientras algo trabaja lo hace girar Core Animation: la capa da vueltas en el
/// servidor de ventanas y Hive no se despierta en cada cuadro. Con `.repeatForever` de SwiftUI la
/// app volvía a armar la ventana a la frecuencia de la pantalla (120 veces por segundo) mientras un
/// agente trabajara, aunque estuvieras en otra app: más de 10% de un núcleo sin hacer nada.
///
/// Las capturas de los tests (`cacheDisplay`) no dibujan estas capas.
class SpinningLayerView: NSView {
    /// La capa que da vueltas: la ubica la subclase.
    let spinner: CALayer
    var spins = true {
        didSet {
            guard spins != oldValue else { return }
            needsLayout = true
            updateSpin()
        }
    }
    private let duration: CFTimeInterval
    private static let spinKey = "hive.spin"

    init(spinner: CALayer, duration: CFTimeInterval) {
        self.spinner = spinner
        self.duration = duration
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Y hacia abajo, como SwiftUI: así el ángulo positivo gira en el sentido del reloj y el
    /// degradé cónico avanza en el mismo sentido que `AngularGradient`.
    override var isFlipped: Bool { true }

    /// El aro está encima del ícono del riel, que es el que recibe los clics.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutAnimation { layoutLayers() }
    }

    /// Acomoda las capas al tamaño de la vista.
    func layoutLayers() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpin()
    }

    /// Cambia capas sin la transición implícita de Core Animation.
    func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    /// Sin ventana no gira; al volver a una, la vuelta se pone de nuevo si se perdió.
    private func updateSpin() {
        if spins && window != nil {
            guard spinner.animation(forKey: Self.spinKey) == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = duration
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            spinner.add(spin, forKey: Self.spinKey)
        } else {
            spinner.removeAnimation(forKey: Self.spinKey)
        }
    }
}

/// El arco de «trabajando» (`WorkingGlyph`): un círculo al 70% que gira. Quieto, un aro entero.
final class SpinningArcView: SpinningLayerView {
    private let arc: CAShapeLayer
    var color: CGColor = .black {
        didSet { withoutAnimation { arc.strokeColor = color } }
    }
    var lineWidth: CGFloat = 1.8 {
        didSet { if lineWidth != oldValue { needsLayout = true } }
    }

    init() {
        let arc = CAShapeLayer()
        arc.fillColor = nil
        arc.lineCap = .round
        self.arc = arc
        super.init(spinner: arc, duration: 0.9)
        layer?.addSublayer(arc)
    }

    override func layoutLayers() {
        arc.frame = bounds
        // Como `Circle().stroke`: el trazo va centrado en el borde del círculo.
        arc.path = CGPath(ellipseIn: arc.bounds, transform: nil)
        arc.lineWidth = lineWidth
        arc.strokeEnd = spins ? 0.7 : 1
    }
}

/// El aro que gira alrededor del ícono de un proyecto (`StatusRing`): un degradé cónico que da
/// vueltas, visto a través de un borde con las esquinas continuas del ícono.
final class SpinningRingView: SpinningLayerView {
    private let gradient: CAGradientLayer
    private let ring = CALayer()
    private let border = CALayer()
    var color: CGColor = .black {
        // Como el `AngularGradient` de antes: de transparente al color lleno, y de golpe transparente.
        didSet { withoutAnimation { gradient.colors = [0, 0.3, 1, 0].map { color.copy(alpha: color.alpha * $0) ?? color } } }
    }
    var lineWidth: CGFloat = 2 {
        didSet { if lineWidth != oldValue { needsLayout = true } }
    }
    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    init() {
        let gradient = CAGradientLayer()
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        self.gradient = gradient
        super.init(spinner: gradient, duration: 1.4)
        border.borderColor = .black
        border.cornerCurve = .continuous
        ring.addSublayer(gradient)
        ring.mask = border
        layer?.addSublayer(ring)
    }

    override func layoutLayers() {
        ring.frame = bounds
        // Como `strokeBorder`: el borde va por dentro del rectángulo.
        border.frame = ring.bounds
        border.borderWidth = lineWidth
        border.cornerRadius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        // Más grande que el aro: al girar, las esquinas siguen cubiertas.
        let side = max(bounds.width, bounds.height) * 1.5
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// `SpinningArcView` para SwiftUI.
struct SpinningArc: NSViewRepresentable {
    let color: Color
    let lineWidth: CGFloat
    let spins: Bool

    func makeNSView(context: Context) -> SpinningArcView { SpinningArcView() }

    func updateNSView(_ view: SpinningArcView, context: Context) {
        view.color = color.resolve(in: context.environment).cgColor
        view.lineWidth = lineWidth
        view.spins = spins
    }
}

/// `SpinningRingView` para SwiftUI.
struct SpinningRing: NSViewRepresentable {
    let color: Color
    let lineWidth: CGFloat
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> SpinningRingView { SpinningRingView() }

    func updateNSView(_ view: SpinningRingView, context: Context) {
        view.color = color.resolve(in: context.environment).cgColor
        view.lineWidth = lineWidth
        view.cornerRadius = cornerRadius
    }
}
