import AppKit
import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// UserDefaults propio de cada prueba (otros procesos de test usan el estándar).
private final class TerminalAppearanceDefaults {
    let name = "hive-appearance-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
}

/// Contraste WCAG entre dos colores.
private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    let (l1, l2) = (luminance(a), luminance(b))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

private func hexColor(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

private func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
    guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
    return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
        && abs(a.blueComponent - b.blueComponent) < 0.01
}

@MainActor
@Suite("Apariencia de la terminal", .serialized)
struct TerminalAppearanceTests {
    func makeTerminal(_ defaults: UserDefaults, appearance: NSAppearance.Name = .darkAqua) -> HiveTerminalView {
        _ = NSApplication.shared
        let view = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), scrollback: 1_000)
        view.appearance = NSAppearance(named: appearance)
        TerminalTheme.apply(to: view, defaults: defaults)
        return view
    }

    @Test("Toma el tamaño, la fuente y el tema de los ajustes")
    func readsPreferences() {
        let store = TerminalAppearanceDefaults()
        store.defaults.set(15.0, forKey: "terminalFontSize")
        store.defaults.set("Menlo", forKey: "terminalFontName")
        store.defaults.set("light", forKey: "terminalTheme")
        let view = makeTerminal(store.defaults)
        #expect(view.font.pointSize == 15)
        #expect(view.font.familyName == "Menlo")
        #expect(sameColor(view.nativeBackgroundColor, TerminalPalette.light.background))
    }

    @Test("Sin ajustes: SF Mono 13 y paleta oscura; el tamaño se limita entre 9 y 28")
    func defaultsAndClamp() {
        let store = TerminalAppearanceDefaults()
        let view = makeTerminal(store.defaults)
        #expect(view.font.pointSize == 13)
        #expect(sameColor(view.nativeBackgroundColor, TerminalPalette.dark.background))
        store.defaults.set(60.0, forKey: "terminalFontSize")
        #expect(TerminalPreferences.read(store.defaults).fontSize == 28)
        store.defaults.set(2.0, forKey: "terminalFontSize")
        #expect(TerminalPreferences.read(store.defaults).fontSize == 9)
    }

    @Test("Cambiar el tamaño cambia todas las terminales, conserva la diferencia y el color del cursor")
    func reappliesFontSize() async {
        let store = TerminalAppearanceDefaults()
        let session = makeTerminal(store.defaults)
        let caret = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        session.caretColor = caret
        // La esquinita de comandos: un punto más chica, como la arma el store.
        let command = makeTerminal(store.defaults)
        command.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        store.defaults.set(16.0, forKey: "terminalFontSize")
        #expect(await waitUntil { session.font.pointSize == 16 && command.font.pointSize == 15 })
        #expect(sameColor(session.caretColor, caret))
        #expect(sameColor(command.caretColor, TerminalTheme.defaultCaret))

        store.defaults.set("Menlo", forKey: "terminalFontName")
        #expect(await waitUntil { command.font.familyName == "Menlo" })
        #expect(command.font.pointSize == 15)

        // Con sizeDelta la terminal nace un punto más chica y con la familia elegida.
        let other = HiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), scrollback: 100)
        TerminalTheme.apply(to: other, defaults: store.defaults, sizeDelta: -1)
        #expect(other.font.pointSize == 15 && other.font.familyName == "Menlo")
        store.defaults.set(20.0, forKey: "terminalFontSize")
        #expect(await waitUntil { other.font.pointSize == 19 })
    }

    @Test("Con el sistema en claro usa la paleta clara, y vuelve a la oscura si el sistema cambia")
    func followsSystem() async {
        let store = TerminalAppearanceDefaults()
        let view = makeTerminal(store.defaults, appearance: .aqua)
        let caret = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.4, alpha: 1)
        view.caretColor = caret
        #expect(sameColor(view.nativeBackgroundColor, TerminalPalette.light.background))
        #expect(sameColor(view.nativeForegroundColor, TerminalPalette.light.foreground))

        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        #expect(sameColor(view.nativeBackgroundColor, TerminalPalette.dark.background))
        #expect(sameColor(view.caretColor, caret))

        // El ajuste «Claro» gana aunque el sistema esté en oscuro.
        store.defaults.set("light", forKey: "terminalTheme")
        #expect(await waitUntil { sameColor(view.nativeBackgroundColor, TerminalPalette.light.background) })
        #expect(sameColor(view.caretColor, caret))
    }

    @Test("El contenedor de la terminal toma su fondo")
    func containerBackground() {
        let store = TerminalAppearanceDefaults()
        store.defaults.set("light", forKey: "terminalTheme")
        let view = makeTerminal(store.defaults)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        host.wantsLayer = true
        host.addSubview(view)
        let color = host.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
        #expect(color.map { sameColor($0, TerminalPalette.light.background) } == true)
    }

    @Test("Paleta clara: texto y los 16 colores ANSI con contraste WCAG ≥ 4,5 sobre #FAFAFB")
    func lightContrast() {
        let light = TerminalPalette.light
        #expect(sameColor(light.background, hexColor(0xFAFAFB)))
        #expect(contrast(light.foreground, light.background) >= 4.5)
        #expect(light.ansi.count == 16)
        for (index, hex) in light.ansi.enumerated() {
            let ratio = contrast(hexColor(hex), light.background)
            #expect(ratio >= 4.5, "El color ANSI \(index) da \(ratio)")
        }
        #expect(contrast(light.foreground, light.selection) >= 4.5)
    }

    @Test("Los ajustes de cursor y Option se leen y tienen nombres en castellano")
    func cursorAndOption() {
        let store = TerminalAppearanceDefaults()
        #expect(TerminalPreferences.read(store.defaults).cursor == .blinkBlock)
        #expect(TerminalPreferences.read(store.defaults).optionKey == .characters)
        store.defaults.set("steadyBar", forKey: "terminalCursor")
        store.defaults.set("meta", forKey: "terminalOptionKey")
        let prefs = TerminalPreferences.read(store.defaults)
        #expect(prefs.cursor == .steadyBar && prefs.cursor.shape == .bar && !prefs.cursor.blinks)
        #expect(prefs.optionKey == .meta)
        #expect(TerminalPreferences.Cursor(shape: .underline, blinking: true) == .blinkUnderline)
        #expect(TerminalPreferences.monospacedFamilies().first == "SF Mono")
    }

    @Test("Las familias monoespaciadas se pueden pedir fuera del hilo principal y traen Menlo")
    func familiesOffMain() async {
        let families = await Task.detached { TerminalPreferences.monospacedFamilies() }.value
        #expect(families.first == "SF Mono")
        #expect(families.contains("Menlo"))
        #expect(Set(families).count == families.count)
    }
}
