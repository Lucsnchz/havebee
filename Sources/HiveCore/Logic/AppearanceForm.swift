import Foundation

/// Lo que se elige en la hoja «Personalizar proyecto» (logo, iniciales, símbolo o emoji), sin la vista.
public struct AppearanceForm: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case logo, initials, symbol, emoji

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .logo: "Logo"
            case .initials: "Iniciales"
            case .symbol: "Símbolo"
            case .emoji: "Emoji"
            }
        }
    }

    public static let defaultSymbol = "cart.fill"
    public static let defaultEmoji = "🐝"

    public var kind: Kind = .initials
    public var symbol = AppearanceForm.defaultSymbol
    public var emoji = AppearanceForm.defaultEmoji
    /// La imagen elegida para el modo «Logo» (un logo del repo o una importada).
    public var imagePath: String?
    /// Los logos encontrados en el repo, el mejor primero.
    public private(set) var logos: [String] = []

    /// Arranca con el ícono actual del proyecto. Los logos pueden llegar después con `setLogos`.
    public init(project: Project, logos: [String] = []) {
        switch project.icon ?? .initials {
        case .initials: kind = .initials
        case .symbol(let value): kind = .symbol; symbol = value
        case .emoji(let value): kind = .emoji; emoji = value
        case .image(let path): kind = .logo; imagePath = path
        }
        setLogos(logos)
    }

    /// Guarda los logos del repo y, si todavía no hay imagen elegida, propone el primero.
    public mutating func setLogos(_ logos: [String]) {
        self.logos = logos
        if imagePath == nil { imagePath = logos.first }
    }

    /// Las imágenes para elegir: la elegida primero si no es uno de los logos del repo.
    public var images: [String] {
        var paths = logos
        if let imagePath, !paths.contains(imagePath) { paths.insert(imagePath, at: 0) }
        return paths
    }

    /// El ícono que queda guardado. Un logo sin imagen o un emoji vacío caen en las iniciales.
    public var icon: ProjectIcon {
        switch kind {
        case .logo: imagePath.map { .image($0) } ?? .initials
        case .initials: .initials
        case .symbol: symbol.isEmpty ? .initials : .symbol(symbol)
        case .emoji: Self.lastEmoji(emoji).map { .emoji($0) } ?? .initials
        }
    }

    // MARK: - Emoji

    /// Lo que se escribió en el campo «Otro»: se queda con el último emoji y descarta letras y números.
    public mutating func typeEmoji(_ text: String) {
        emoji = Self.lastEmoji(text) ?? ""
    }

    /// Al salir del campo: si quedó vacío, el ícono vuelve a las iniciales (y el selector lo muestra).
    public mutating func finishEmoji() {
        if kind == .emoji && Self.lastEmoji(emoji) == nil { kind = .initials }
    }

    /// El último emoji de un texto, entero: banderas (🇦🇷), familias con ZWJ (👨‍👩‍👧), tonos de piel y
    /// teclas (1️⃣). Las letras, los números y los símbolos de texto no cuentan.
    public static func lastEmoji(_ text: String) -> String? {
        text.reversed().first(where: isEmoji).map(String.init)
    }

    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first, first.properties.isEmoji else { return false }
        // Se dibuja como emoji por defecto (🐝, banderas) o lleva algo que lo convierte (🛡️, 1️⃣, 👍🏽, ZWJ).
        if first.properties.isEmojiPresentation { return true }
        return scalars.dropFirst().contains { $0 == "\u{FE0F}" || $0 == "\u{20E3}" || $0 == "\u{200D}" || $0.properties.isEmojiModifier }
    }
}
