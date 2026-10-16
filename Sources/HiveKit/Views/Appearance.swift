import AppKit
import HiveCore
import SwiftUI

// MARK: - Colores

extension TintColor {
    var nsColor: NSColor { NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
    var color: Color { Color(nsColor: nsColor) }

    /// Circulito de color para usar en menús (los menús de macOS no dibujan vistas de SwiftUI).
    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Ícono de proyecto

struct ProjectTile: View {
    let project: Project
    var size: CGFloat = 20
    /// Si se pasa, se dibuja el aro con el estado de las sesiones del proyecto (el único borde del ícono).
    var activity: Activity? = nil
    /// Globito con la cantidad de sesiones que te esperan («!» delante si alguna pide permiso).
    var showsBadge = false

    var body: some View {
        tile
            .overlay { StatusRing(ring: activity?.ring ?? .none, size: size) }
            .overlay(alignment: .topTrailing) {
                if showsBadge, let activity {
                    ActivityBadge(activity: activity, outlined: true)
                        .offset(x: size * 0.18, y: -size * 0.18)
                }
            }
    }

    @ViewBuilder private var tile: some View {
        let tint = project.tint.color
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            switch project.icon ?? .initials {
            case .initials:
                shape.fill(tint.gradient)
                Text(project.initials)
                    .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            case .symbol(let name):
                shape.fill(tint.gradient)
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            case .emoji(let emoji):
                shape.fill(tint.opacity(0.28))
                Text(emoji)
                    .font(.system(size: size * 0.64))
            case .image(let path):
                if let image = ImageCache.image(at: path) {
                    // El color del proyecto queda en el fondo, apenas, detrás del logo: así se sigue
                    // distinguiendo sin otro borde que se confunda con el aro de estado.
                    shape.fill(Color(white: 0.97))
                    shape.fill(tint.opacity(0.22))
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(size * 0.1)
                } else {
                    shape.fill(tint.gradient)
                    Text(project.initials)
                        .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

/// Un proyecto apagado (sin nada prendido ni usado hoy), en el riel y en el árbol: casi sin color y
/// un poco transparente, pero legible. Se apaga sobre todo sacándole el color: el gris conserva la
/// luminancia del tinte, así las iniciales blancas siguen contrastando. Con mucha transparencia el
/// relleno se iba hacia el fondo (en claro, las iniciales de un ícono naranja quedaban a 1,5:1).
struct DimmedProject: ViewModifier {
    let dimmed: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Cuánto color le queda: un poco, para reconocerlo por el color sin que parezca prendido.
    static let saturation = 0.3

    /// En claro casi no se transparenta: el fondo es claro y aclararía el relleno hasta perder las iniciales.
    static func opacity(for scheme: ColorScheme) -> Double { scheme == .dark ? 0.65 : 0.85 }

    /// Cuándo se atenúa, igual en el riel y en el árbol: sin actividad hoy, salvo que sea el
    /// proyecto abierto (o tenga elegida una rama o sesión suya) o que tenga el puntero encima.
    static func dims(isActive: Bool, isCurrent: Bool, hovering: Bool) -> Bool {
        !isActive && !isCurrent && !hovering
    }

    func body(content: Content) -> some View {
        content
            .saturation(dimmed ? Self.saturation : 1)
            .opacity(dimmed ? Self.opacity(for: colorScheme) : 1)
            .animation(.easeOut(duration: 0.2), value: dimmed)
    }
}

extension View {
    func dimmedProject(_ dimmed: Bool) -> some View { modifier(DimmedProject(dimmed: dimmed)) }
}

/// El único aro alrededor del ícono, y solo de estado: un arco del acento que gira si algo está
/// trabajando (con «Reducir movimiento», un aro fijo), naranja lleno si algo necesita permiso,
/// verde si algo te espera y nada si no pasa nada. El punteado queda para «agregar» y «soltar
/// acá»; como el naranja y el verde se distinguen solo por el color, el permiso lleva además el
/// «!» del globito (`ActivityBadge`).
struct StatusRing: View {
    let ring: Activity.Ring
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ancho del aro: fino en los íconos grandes para que no parezca el foco del teclado.
    static func lineWidth(for size: CGFloat) -> CGFloat { min(2.5, max(1.5, size * 0.06)) }

    var body: some View {
        let width = Self.lineWidth(for: size)
        let gap = max(2, size * 0.06)
        let shape = RoundedRectangle(cornerRadius: size * 0.27 + gap, style: .continuous)
        // El color sale de `StatusStyle`, como el de las tarjetas, el Inicio, ⌘K y las pestañas.
        let color = StatusStyle.of(ring: ring).color ?? .clear
        ZStack {
            switch ring {
            case .none:
                EmptyView()
            case .pending, .attention:
                shape.strokeBorder(color, lineWidth: width)
                    .transition(.opacity)
            case .working:
                if reduceMotion {
                    shape.strokeBorder(color, lineWidth: width)
                } else {
                    SpinningGradient(color: color)
                        .mask(shape.strokeBorder(lineWidth: width))
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: ring)
        .padding(-(gap + width))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Degradé angular fijo que gira con `rotationEffect`: lo interpola Core Animation, sin volver a
/// armar la vista 30 veces por segundo como hacía el TimelineView.
private struct SpinningGradient: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        AngularGradient(colors: [color.opacity(0), color.opacity(0.3), color, color.opacity(0)],
                        center: .center)
            // Más grande que el aro: al girar, las esquinas siguen cubiertas.
            .scaleEffect(1.5)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// Imágenes de los proyectos ya leídas (y las rutas que no se pudieron leer). Solo desde las vistas.
@MainActor
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()
    private static var missing = Set<String>()

    static func image(at path: String) -> NSImage? {
        if let image = cache.object(forKey: path as NSString) { return image }
        if missing.contains(path) { return nil }
        guard let image = NSImage(contentsOfFile: path), image.isValid else {
            missing.insert(path)
            return nil
        }
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    static func forget(_ path: String) {
        cache.removeObject(forKey: path as NSString)
        missing.remove(path)
    }
}

enum IconChoices {
    static let symbols = [
        "cart.fill", "bag.fill", "creditcard.fill", "dollarsign.circle.fill", "chart.bar.fill", "chart.pie.fill",
        "building.2.fill", "house.fill", "storefront.fill", "briefcase.fill", "globe", "network",
        "server.rack", "cloud.fill", "externaldrive.fill", "cpu", "iphone", "laptopcomputer",
        "gamecontroller.fill", "paintbrush.fill", "paintpalette.fill", "camera.fill", "photo.fill", "film.fill",
        "music.note", "book.fill", "graduationcap.fill", "person.2.fill", "message.fill", "envelope.fill",
        "bell.fill", "bolt.fill", "flame.fill", "leaf.fill", "airplane", "car.fill",
        "tram.fill", "fork.knife", "cup.and.saucer.fill", "heart.fill", "star.fill", "shield.fill",
        "lock.fill", "key.fill", "wrench.and.screwdriver.fill", "hammer.fill", "ant.fill", "terminal.fill",
        "curlybraces", "cube.fill", "shippingbox.fill", "puzzlepiece.fill", "sparkles", "wand.and.stars",
        "map.fill", "stethoscope", "pawprint.fill", "tshirt.fill", "trophy.fill", "hexagon.fill",
    ]

    static let emojis = [
        "🐝", "🍯", "🚀", "🔥", "⚡️", "🧠", "🛒", "💳", "🏦", "📱", "🎮", "🎨",
        "📦", "🛡️", "🤖", "🌐", "📊", "🧪", "🚆", "🍕", "☕️", "🎵", "🏠", "⭐️",
    ]
}

// MARK: - Logos de los agentes

/// Logo original de cada agente (Resources/Logos). La terminal usa un símbolo del sistema.
struct AgentLogo: View {
    let kind: SessionKind
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = AgentLogo.image(kind) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "terminal.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
    }

    @MainActor private static var images: [SessionKind: NSImage] = [:]
    @MainActor private static var menuImages: [SessionKind: NSImage] = [:]

    @MainActor static func image(_ kind: SessionKind) -> NSImage? {
        if let cached = images[kind] { return cached }
        guard let svg = LogoAssets.svg(for: kind.rawValue), let image = NSImage(data: Data(svg.utf8)) else { return nil }
        // Los SVG traen un tamaño de 1×1 ("1em"): les damos uno real para que se dibujen nítidos.
        image.size = NSSize(width: 128, height: 128)
        images[kind] = image
        return image
    }

    /// Imagen del logo para menús contextuales.
    @MainActor static func menuImage(_ kind: SessionKind) -> NSImage {
        if let cached = menuImages[kind] { return cached }
        let result: NSImage
        if let logo = image(kind)?.copy() as? NSImage {
            logo.size = NSSize(width: 16, height: 16)
            result = logo
        } else {
            result = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
            result.isTemplate = true
        }
        menuImages[kind] = result
        return result
    }
}
