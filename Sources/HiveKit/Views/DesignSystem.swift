import AppKit
import SwiftUI

// MARK: - Colores

/// Colores de Hive. Hay un solo acento: miel en oscuro y un ámbar más oscuro en claro, para que
/// el texto en acento se lea (contraste ≥ 4,5) sobre blanco y también sobre las tarjetas, con el
/// mouse encima incluido. Los rellenos usan `accentFill`, que es miel en las dos apariencias.
///
/// El naranja (`attention`) y el verde (`pending`) son solo de los estados de las sesiones. Para lo
/// demás hay tokens propios: `running` (un comando corriendo), `danger` (errores, fallas, detener),
/// `info` (avisos neutros) y `secondaryText` (datos en gris que hay que poder leer).
enum Theme {
    /// Acento como NSColor dinámico (cambia solo con la apariencia). Es para texto, bordes y trazos.
    static let accentNSColor = dynamicNSColor(light: srgb(0x8F5F00),
                                              dark: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 1))
    static let accent = Color(nsColor: accentNSColor)

    /// Relleno con el acento (botón principal, círculos de pasos, selección): miel también en claro,
    /// donde el ámbar de texto se veía marrón.
    static let accentFillNSColor = dynamicNSColor(light: srgb(0xE8A92A),
                                                  dark: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 1))
    static let accentFill = Color(nsColor: accentFillNSColor)

    /// Texto sobre `accentFill`: negro suave en las dos apariencias (más de 8:1).
    static let onAccentFillNSColor = NSColor(white: 0, alpha: 0.85)
    static let onAccentFill = Color(nsColor: onAccentFillNSColor)

    /// Texto sobre un globito de estado (naranja, verde o el acento de texto): negro suave en oscuro,
    /// blanco en claro.
    static let onAccentNSColor = dynamicNSColor(light: .white, dark: NSColor(white: 0, alpha: 0.85))
    static let onAccent = Color(nsColor: onAccentNSColor)

    /// Necesita permiso: naranja (más oscuro en claro para que se lea como texto).
    static let attentionNSColor = dynamicNSColor(light: srgb(0xB54708), dark: .systemOrange)
    static let attention = Color(nsColor: attentionNSColor)

    /// Te espera y no la viste: verde (más oscuro en claro, para que se lea también sobre una tarjeta).
    static let pendingNSColor = dynamicNSColor(light: srgb(0x187A34), dark: .systemGreen)
    static let pending = Color(nsColor: pendingNSColor)

    /// Avisos neutros (información, sin nada urgente): azul que se lee en claro y en oscuro.
    static let infoNSColor = dynamicNSColor(light: srgb(0x1A5FB4), dark: srgb(0x4DA3FF))
    static let info = Color(nsColor: infoNSColor)

    /// Un comando corriendo (servidor, tests…). Azul, para no confundirlo con el verde de «te espera».
    static let runningNSColor = infoNSColor
    static let running = Color(nsColor: runningNSColor)

    /// Errores, fallas y detener: rojo oscurecido en claro (como el naranja) y más suave en oscuro.
    static let dangerNSColor = dynamicNSColor(light: srgb(0xB42318), dark: srgb(0xFF6961))
    static let danger = Color(nsColor: dangerNSColor)

    /// Texto secundario que da un dato (fechas, rutas, rama, autor, comando): como el gris
    /// secundario del sistema, pero un poco más oscuro en claro para llegar a 4,5 sobre las tarjetas.
    /// `.tertiary` queda para separadores e íconos de adorno.
    static let secondaryTextNSColor = dynamicNSColor(light: NSColor(white: 0, alpha: 0.58), dark: NSColor(white: 1, alpha: 0.55))
    static let secondaryText = Color(nsColor: secondaryTextNSColor)

    /// Un NSColor que elige el valor según la apariencia (claro u oscuro, también en alto contraste).
    static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// Color sRGB a partir de un hex 0xRRGGBB.
    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// Un color que cambia con la apariencia: `light` en modo claro y `dark` en oscuro.
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: Theme.dynamicNSColor(light: NSColor(light), dark: NSColor(dark)))
    }
}

/// Contraste WCAG 2 entre colores (para los tests de legibilidad).
enum HiveContrast {
    /// Resuelve un color (dinámico o no) en una apariencia y lo pasa a sRGB.
    static func resolve(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    /// Luminancia relativa (0 negro, 1 blanco).
    static func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// Mezcla un color con transparencia sobre un fondo opaco.
    static func composite(_ color: NSColor, over background: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let b = background.usingColorSpace(.sRGB) ?? background
        let a = c.alphaComponent
        return NSColor(srgbRed: c.redComponent * a + b.redComponent * (1 - a),
                       green: c.greenComponent * a + b.greenComponent * (1 - a),
                       blue: c.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }

    /// Relación de contraste (1 a 21) de un color sobre un fondo opaco.
    static func ratio(_ foreground: NSColor, on background: NSColor) -> Double {
        let fg = luminance(composite(foreground, over: background))
        let bg = luminance(background)
        return (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
    }
}

// MARK: - Tipografía

/// La escala tipográfica de Hive: siete tamaños y nada más.
enum HiveFont {
    static let title = Font.system(size: 20, weight: .bold)
    static let heading = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let secondary = Font.system(size: 12)
    static let meta = Font.system(size: 11)
    /// Títulos de sección (en mayúsculas, con `.tracking(0.6)`).
    static let section = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
}

// MARK: - Tarjetas

/// Fondo y borde comunes de las tarjetas. Con `interactive`, se aclara al pasar el mouse; con
/// `dashed`, es la tarjeta punteada de «agregar» (sin relleno hasta que pasás el mouse).
struct HiveCard: ViewModifier {
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
    /// Grilla común de tarjetas: columnas de 260 pt como mínimo, alineadas arriba.
    static let gridColumns = [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)]

    var interactive = false
    var dashed = false
    var radius: CGFloat = HiveCard.cardRadius
    /// Borde de estado (ej. naranja si pide permiso); reemplaza al borde neutro.
    var border: Color?
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let hover = interactive && hovering
        let fill: Double = dashed ? (hover ? 0.045 : 0) : (hover ? 0.075 : 0.045)
        let stroke: Double = dashed ? (hover ? 0.26 : 0.18) : (hover ? 0.16 : 0.08)
        content
            .background(Color.primary.opacity(fill), in: shape)
            .overlay {
                shape.strokeBorder(border ?? Color.primary.opacity(stroke),
                                   style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
            }
            .contentShape(shape)
            .onHover { inside in
                if interactive { hovering = inside }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hiveCard(interactive: Bool = false, dashed: Bool = false, radius: CGFloat = HiveCard.cardRadius, border: Color? = nil) -> some View {
        modifier(HiveCard(interactive: interactive, dashed: dashed, radius: radius, border: border))
    }

    /// Tarjeta neutra (se mantiene por compatibilidad: es `.hiveCard()`).
    func cardBackground() -> some View { hiveCard() }
}

// MARK: - Botones

/// Botón principal con el acento: texto negro suave sobre miel, en claro y en oscuro. Es también el
/// del botón de Return de cada hoja: el botón por defecto de macOS se pinta con el `.tint` de la
/// ventana (el ámbar de texto, marrón como relleno) o con el azul del sistema, nunca con el miel.
struct HiveProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HiveProminentLabel(configuration: configuration)
    }
}

private struct HiveProminentLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .font(.system(size: small ? 11 : 13, weight: .semibold))
            .foregroundStyle(Theme.onAccentFill)
            .padding(.horizontal, small ? 8 : 12)
            .padding(.vertical, small ? 3 : 5)
            .background(Theme.accentFill.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: small ? 5 : 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == HiveProminentButtonStyle {
    static var hiveProminent: HiveProminentButtonStyle { HiveProminentButtonStyle() }
}

// MARK: - Secciones

/// Título de sección: mayúsculas chicas, separadas, en gris.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(HiveFont.section)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Sección de una vista de detalle: título y, opcionalmente, algo a la derecha (ej. «Agregar»).
struct DetailSection<Trailing: View, Content: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle(title)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: 20)
            content
        }
    }
}

extension DetailSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

/// Encabezado plegable con chevron (Preparados / Cambios, Archivadas…).
struct DisclosureHeader: View {
    let title: String
    var count: Int?
    @Binding var expanded: Bool
    /// Ocupa todo el ancho, con la cantidad a la derecha (en listas); si no, la cantidad va al lado.
    var fillsWidth = true

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Text(title.uppercased())
                    .font(HiveFont.section)
                    .tracking(0.6)
                if fillsWidth { Spacer(minLength: 4) }
                if let count {
                    Text("\(count)")
                        .font(HiveFont.section.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)\(count.map { ", \($0)" } ?? "")")
        .accessibilityValue(expanded ? "Expandido" : "Contraído")
    }
}

/// Aviso destacado con ícono, texto y una acción opcional.
struct Callout: View {
    let icon: String
    let color: Color
    let title: String
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(HiveFont.heading)
                Text(text)
                    .font(HiveFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action.0, action: action.1)
            }
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: HiveCard.rowRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Ruta en monoespaciada chica, abreviada con «~» y cortada por el principio (lo que importa es
/// la carpeta final). El botón de copiar aparece al pasar el mouse.
struct CopyablePath: View {
    let path: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(path.tildePath)
                .font(HiveFont.mono)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(path)
            Button {
                ExternalApps.copyToPasteboard(path)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Copiar ruta")
            .accessibilityLabel("Copiar ruta")
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Texto

extension String {
    /// La ruta con «~» en lugar de la carpeta personal.
    var tildePath: String { (self as NSString).abbreviatingWithTildeInPath }
}

// MARK: - Fecha de referencia

private struct HiveNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// «Ahora» para las fechas relativas. nil usa el reloj real; los tests de vistas lo fijan para
    /// que las capturas no cambien día a día.
    var hiveNow: Date? {
        get { self[HiveNowKey.self] }
        set { self[HiveNowKey.self] = newValue }
    }
}

enum RelativeTime {
    /// «hace 5 minutos», «ayer»… relativo a `now`.
    static func string(_ date: Date, relativeTo now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Tiempo transcurrido como «2:14» o «1:02:09».
    static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
