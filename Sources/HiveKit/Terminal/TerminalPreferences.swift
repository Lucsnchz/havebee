import AppKit
import CoreText
import SwiftTerm

/// Ajustes de la terminal guardados en UserDefaults. Los cambian Ajustes › Terminal y el zoom
/// (⌘+ / ⌘−), y cada terminal abierta los vuelve a aplicar sola.
struct TerminalPreferences: Equatable {
    static let fontSizeKey = "terminalFontSize"
    static let fontNameKey = "terminalFontName"
    static let cursorKey = "terminalCursor"
    static let themeKey = "terminalTheme"
    static let optionKeyKey = "terminalOptionKey"

    static let defaultFontSize = 13.0
    static let fontSizeRange = 9.0...28.0
    /// Nombre que se guarda para la fuente monoespaciada del sistema.
    static let systemFontName = "SF Mono"

    enum Theme: String, CaseIterable, Identifiable {
        case system, dark, light
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: "Seguir al sistema"
            case .dark: "Oscuro"
            case .light: "Claro"
            }
        }
    }

    /// Qué hace la tecla ⌥ (Option) con las letras y los símbolos.
    enum OptionKey: String, CaseIterable, Identifiable {
        /// Escribe lo que dibuja el teclado: ñ, tildes, @, corchetes (como Terminal.app).
        case characters
        /// Funciona como Meta (Alt): manda ESC y la tecla.
        case meta
        var id: String { rawValue }
        var label: String {
            switch self {
            case .characters: "Escribe caracteres (ñ, tildes, @)"
            case .meta: "Funciona como Meta (Alt)"
            }
        }
    }

    enum CursorShape: String, CaseIterable, Identifiable {
        case block, bar, underline
        var id: String { rawValue }
        var label: String {
            switch self {
            case .block: "Bloque"
            case .bar: "Barra"
            case .underline: "Subrayado"
            }
        }
    }

    /// El cursor, con los mismos nombres que `CursorStyle` de SwiftTerm.
    enum Cursor: String, CaseIterable {
        case blinkBlock, steadyBlock, blinkBar, steadyBar, blinkUnderline, steadyUnderline

        init(shape: CursorShape, blinking: Bool) {
            switch (shape, blinking) {
            case (.block, true): self = .blinkBlock
            case (.block, false): self = .steadyBlock
            case (.bar, true): self = .blinkBar
            case (.bar, false): self = .steadyBar
            case (.underline, true): self = .blinkUnderline
            case (.underline, false): self = .steadyUnderline
            }
        }

        var shape: CursorShape {
            switch self {
            case .blinkBlock, .steadyBlock: .block
            case .blinkBar, .steadyBar: .bar
            case .blinkUnderline, .steadyUnderline: .underline
            }
        }

        var blinks: Bool {
            switch self {
            case .blinkBlock, .blinkBar, .blinkUnderline: true
            default: false
            }
        }

        var style: CursorStyle {
            switch self {
            case .blinkBlock: .blinkBlock
            case .steadyBlock: .steadyBlock
            case .blinkBar: .blinkBar
            case .steadyBar: .steadyBar
            case .blinkUnderline: .blinkUnderline
            case .steadyUnderline: .steadyUnderline
            }
        }
    }

    var fontSize = Self.defaultFontSize
    var fontName = Self.systemFontName
    var cursor = Cursor.blinkBlock
    var theme = Theme.system
    var optionKey = OptionKey.characters

    static func read(_ defaults: UserDefaults = .standard) -> TerminalPreferences {
        var prefs = TerminalPreferences()
        if let size = defaults.object(forKey: fontSizeKey) as? Double { prefs.fontSize = clampedSize(size) }
        if let name = defaults.string(forKey: fontNameKey), !name.isEmpty { prefs.fontName = name }
        if let cursor = defaults.string(forKey: cursorKey).flatMap(Cursor.init(rawValue:)) { prefs.cursor = cursor }
        if let theme = defaults.string(forKey: themeKey).flatMap(Theme.init(rawValue:)) { prefs.theme = theme }
        if let option = defaults.string(forKey: optionKeyKey).flatMap(OptionKey.init(rawValue:)) { prefs.optionKey = option }
        return prefs
    }

    static func clampedSize(_ size: Double) -> Double {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// La fuente elegida a `size` puntos (SF Mono si la familia no está instalada).
    func font(size: CGFloat) -> NSFont {
        if fontName != Self.systemFontName,
           let font = NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Si con esta apariencia toca la paleta clara.
    func usesLightPalette(for appearance: NSAppearance) -> Bool {
        switch theme {
        case .dark: false
        case .light: true
        case .system: appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
        }
    }

    /// Las familias monoespaciadas instaladas (para elegir en Ajustes), con SF Mono primero. Usa
    /// CoreText y no NSFontManager: Ajustes la llama fuera del hilo principal.
    static func monospacedFamilies() -> [String] {
        let monospaced = CTFontDescriptorCreateWithAttributes(
            [kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([monospaced] as CFArray, nil)
        let descriptors = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor]) ?? []
        let families = Set(descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })
            .filter { !$0.hasPrefix(".") && $0 != systemFontName }
        return [systemFontName] + families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Colores de la terminal en oscuro o en claro.
struct TerminalPalette {
    let background: NSColor
    let foreground: NSColor
    let selection: NSColor
    /// Los 16 colores ANSI (8 normales y 8 brillantes), en hexadecimal.
    let ansi: [UInt32]
    let colorScheme: TerminalColorScheme

    static let dark = TerminalPalette(
        background: NSColor(srgbRed: 0.075, green: 0.078, blue: 0.094, alpha: 1),
        foreground: NSColor(srgbRed: 0.87, green: 0.87, blue: 0.89, alpha: 1),
        selection: NSColor(srgbRed: 0.24, green: 0.30, blue: 0.42, alpha: 1),
        ansi: [0x2A2B33, 0xF07178, 0x9FD18B, 0xF5C26B, 0x7AA7F5, 0xC69CF0, 0x6FCFD1, 0xD4D4D8,
               0x5E606E, 0xFF8E94, 0xB8E6A3, 0xFFD88C, 0x9CC1FF, 0xDBB8FF, 0x93E5E6, 0xF5F5F7],
        colorScheme: .dark)

    /// Fondo #FAFAFB y texto #1F2328. Todos los colores ANSI tienen contraste ≥ 4,5 sobre el
    /// fondo (el amarillo y los blancos van oscurecidos para que se lean).
    static let light = TerminalPalette(
        background: NSColor(srgbRed: 0xFA / 255.0, green: 0xFA / 255.0, blue: 0xFB / 255.0, alpha: 1),
        foreground: NSColor(srgbRed: 0x1F / 255.0, green: 0x23 / 255.0, blue: 0x28 / 255.0, alpha: 1),
        selection: NSColor(srgbRed: 0xC8 / 255.0, green: 0xDD / 255.0, blue: 0xF8 / 255.0, alpha: 1),
        ansi: [0x24292F, 0xC4252B, 0x116329, 0x7A4E00, 0x0757B8, 0x8250DF, 0x1A6F78, 0x57606A,
               0x656E78, 0xA40E26, 0x1A7F37, 0x633C01, 0x0550AE, 0x6639BA, 0x136061, 0x4B535D],
        colorScheme: .light)

    var terminalColors: [SwiftTerm.Color] {
        ansi.map { hex in
            SwiftTerm.Color(red8: UInt16((hex >> 16) & 0xFF), green8: UInt16((hex >> 8) & 0xFF), blue8: UInt16(hex & 0xFF))
        }
    }
}

enum TerminalTheme {
    /// Color del cursor cuando nadie elige otro (los comandos; las sesiones usan el del proyecto).
    static let defaultCaret = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 1)

    /// Fondo de la terminal según la apariencia y el ajuste de tema, para lo que la rodea.
    static let background = NSColor(name: "hiveTerminalBackground") { appearance in
        palette(for: appearance).background
    }

    static let foreground = NSColor(name: "hiveTerminalForeground") { appearance in
        palette(for: appearance).foreground
    }

    static func palette(for appearance: NSAppearance, preferences: TerminalPreferences = .read()) -> TerminalPalette {
        preferences.usesLightPalette(for: appearance) ? .light : .dark
    }

    /// Configura una terminal nueva con los ajustes de `defaults`. Después, cada `HiveTerminalView`
    /// los vuelve a aplicar sola cuando cambian (o cuando cambia la apariencia del sistema).
    /// `sizeDelta`: puntos de más o de menos respecto del tamaño elegido (la esquinita de
    /// comandos usa -1); se conserva cuando el tamaño cambia.
    @MainActor
    static func apply(to view: TerminalView, defaults: UserDefaults = .standard, sizeDelta: Double = 0) {
        let prefs = TerminalPreferences.read(defaults)
        view.font = prefs.font(size: CGFloat(max(6, prefs.fontSize + sizeDelta)))
        applyColors(palette(for: view.effectiveAppearance, preferences: prefs), to: view)
        view.caretColor = defaultCaret
        view.setCursorStyle(prefs.cursor.style)
        // ⌥ queda como Meta; HiveTerminalView lo apaga tecla por tecla para escribir ñ, @ y tildes.
        view.optionAsMetaKey = true
        if let terminal = view as? HiveTerminalView { terminal.preferencesApplied(prefs, from: defaults) }
    }

    @MainActor
    static func applyColors(_ palette: TerminalPalette, to view: TerminalView) {
        view.nativeBackgroundColor = palette.background
        view.nativeForegroundColor = palette.foreground
        view.selectedTextBackgroundColor = palette.selection
        view.installColors(palette.terminalColors)
        // Avisa a Claude y Codex (modo 2031) para que adapten sus colores.
        view.updateColorScheme(palette.colorScheme)
        // El margen alrededor de la terminal toma el mismo fondo.
        view.superview?.layer?.backgroundColor = palette.background.cgColor
    }
}
