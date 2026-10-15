import AppKit
import Foundation
import Testing
@testable import HiveKit

/// Fondos sobre los que se lee el texto: blanco en claro y el fondo de ventana en oscuro.
@MainActor
private func contrastBackground(_ appearance: NSAppearance.Name) -> NSColor {
    appearance == .aqua ? .white : HiveContrast.resolve(.windowBackgroundColor, in: .darkAqua)
}

@MainActor
private func contrastRatio(_ color: NSColor, _ appearance: NSAppearance.Name) -> Double {
    HiveContrast.ratio(HiveContrast.resolve(color, in: appearance), on: contrastBackground(appearance))
}

/// Legibilidad según WCAG 2: 4,5 para texto y 3 para íconos.
@MainActor
@Suite("Contraste")
struct ContrastTests {
    @Test("La fórmula da lo conocido: negro sobre blanco 21, blanco sobre blanco 1")
    func formula() {
        #expect(abs(HiveContrast.ratio(.black, on: .white) - 21) < 0.01)
        #expect(abs(HiveContrast.ratio(.white, on: .white) - 1) < 0.01)
        // #767676 es el gris más claro que da 4,5 sobre blanco.
        #expect(abs(HiveContrast.ratio(Theme.srgb(0x767676), on: .white) - 4.54) < 0.02)
    }

    @Test("El acento: ≥ 4,5 sobre blanco en claro y sobre el fondo en oscuro")
    func accent() {
        #expect(contrastRatio(Theme.accentNSColor, .aqua) >= 4.5)
        #expect(contrastRatio(Theme.accentNSColor, .darkAqua) >= 4.5)
        // Es el miel de siempre en oscuro.
        let dark = HiveContrast.resolve(Theme.accentNSColor, in: .darkAqua)
        #expect(abs(dark.redComponent - 0.96) < 0.01 && abs(dark.greenComponent - 0.72) < 0.01 && abs(dark.blueComponent - 0.24) < 0.01)
    }

    @Test("Texto sobre el acento y sobre los globitos de estado (botón principal): ≥ 4,5")
    func onAccent() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let text = HiveContrast.resolve(Theme.onAccentNSColor, in: appearance)
            for fill in [Theme.accentNSColor, Theme.attentionNSColor, Theme.pendingNSColor] {
                let background = HiveContrast.resolve(fill, in: appearance)
                #expect(HiveContrast.ratio(text, on: background) >= 4.5, "\(appearance.rawValue): \(fill)")
            }
        }
    }

    @Test("Naranja de permiso y verde de «te espera» se leen como texto")
    func statusColors() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(contrastRatio(Theme.attentionNSColor, appearance) >= 4.5, "\(appearance.rawValue)")
            #expect(contrastRatio(Theme.pendingNSColor, appearance) >= 4.5, "\(appearance.rawValue)")
        }
    }

    @Test("Colores de git: ≥ 4,5 en claro y en oscuro")
    func gitColors() throws {
        for badge in ["M", "A", "U", "R", "C", "D", "!"] {
            let color = try #require(ChangeColors.nsColor(for: badge))
            #expect(contrastRatio(color, .aqua) >= 4.5, "\(badge) en claro: \(contrastRatio(color, .aqua))")
            #expect(contrastRatio(color, .darkAqua) >= 4.5, "\(badge) en oscuro: \(contrastRatio(color, .darkAqua))")
        }
        #expect(ChangeColors.nsColor(for: "?") == nil)
        // Los de VS Code Light+ en claro.
        let modified = HiveContrast.resolve(try #require(ChangeColors.nsColor(for: "M")), in: .aqua)
        #expect(abs(modified.redComponent - 0x89 / 255.0) < 0.01 && abs(modified.greenComponent - 0x55 / 255.0) < 0.01)
    }

    @Test("Íconos de JS, JSON y .env: ≥ 3 en claro y en oscuro")
    func fileIcons() {
        for path in ["app.js", "package.json", "config.json", ".env", ".env.local", "tsconfig.jsonc"] {
            let color = FileIconSpec.for(path).nsColor
            #expect(contrastRatio(color, .aqua) >= 3, "\(path) en claro: \(contrastRatio(color, .aqua))")
            #expect(contrastRatio(color, .darkAqua) >= 3, "\(path) en oscuro: \(contrastRatio(color, .darkAqua))")
        }
    }

    @Test("Los íconos oscuros no cambian en claro; los claros bajan el brillo a 0,62")
    func fileIconLightVariant() {
        // TypeScript (#3178C6) ya se lee sobre blanco: queda igual.
        let ts = FileIconSpec.lightVariant(of: 0x3178C6)
        #expect(abs(ts.redComponent - 0x31 / 255.0) < 0.01 && abs(ts.blueComponent - 0xC6 / 255.0) < 0.01)
        // JS (#F1DD3F): mismo tono, brillo × 0,62.
        let js = FileIconSpec.lightVariant(of: 0xF1DD3F)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        js.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #expect(abs(brightness - (0xF1 / 255.0) * 0.62) < 0.01)
        // En oscuro, el color original.
        let dark = HiveContrast.resolve(FileIconSpec.for("app.js").nsColor, in: .darkAqua)
        #expect(abs(dark.redComponent - 0xF1 / 255.0) < 0.01)
    }
}
