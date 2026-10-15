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
    /// Si se pasa, se dibuja un borde con el estado de las sesiones del proyecto.
    var activity: Activity? = nil
    /// Globito con la cantidad de sesiones que te esperan.
    var showsBadge = false

    var body: some View {
        tile
            .overlay { StatusRing(ring: activity?.ring ?? .none, size: size) }
            .overlay(alignment: .topTrailing) {
                if showsBadge, let activity, activity.waitingForYou > 0 {
                    // «!» si algo pide permiso (no solo el color), si no cuántas te esperan.
                    Text(activity.badgeText)
                        .font(.system(size: max(9, size * 0.26), weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 4)
                        .frame(minWidth: size * 0.4, minHeight: size * 0.4)
                        .background(activity.ring.color ?? Theme.pending, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: size * 0.18, y: -size * 0.18)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel(activity.attention > 0 ? "Necesita permiso" : "\(activity.waitingForYou) te esperan")
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
                    shape.fill(Color(white: 0.97))
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
        .overlay {
            // Con logo, un borde del color del proyecto mantiene la distinción por color.
            if case .image? = project.icon {
                shape.strokeBorder(tint, lineWidth: max(1.5, size * 0.07))
            }
        }
    }
}

/// Borde alrededor del ícono: arco miel que gira si algo está trabajando, verde si algo te espera
/// y naranja punteado si algo necesita permiso (se distingue también sin ver los colores).
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
        ZStack {
            switch ring {
            case .none:
                EmptyView()
            case .pending:
                shape.strokeBorder(Theme.pending, lineWidth: width)
                    .transition(.opacity)
            case .attention:
                shape.strokeBorder(Theme.attention, style: StrokeStyle(lineWidth: width, lineCap: .round,
                                                                       dash: [size * 0.18, size * 0.08]))
                    .transition(.opacity)
            case .working:
                if reduceMotion {
                    shape.strokeBorder(Theme.accent, lineWidth: width)
                } else {
                    SpinningGradient()
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
    @State private var spinning = false

    var body: some View {
        AngularGradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.3), Theme.accent, Theme.accent.opacity(0)],
                        center: .center)
            // Más grande que el aro: al girar, las esquinas siguen cubiertas.
            .scaleEffect(1.5)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

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
