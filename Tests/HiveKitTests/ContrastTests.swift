import AppKit
import Foundation
import SwiftUI
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

    @Test("Color.dynamic elige el valor según la apariencia")
    func dynamicColor() {
        let color = NSColor(Color.dynamic(light: Color(nsColor: Theme.srgb(0x9A6700)), dark: .white))
        let light = HiveContrast.resolve(color, in: .aqua)
        let dark = HiveContrast.resolve(color, in: .darkAqua)
        #expect(abs(light.redComponent - 0x9A / 255.0) < 0.01 && abs(light.blueComponent) < 0.01)
        #expect(abs(dark.redComponent - 1) < 0.01 && abs(dark.blueComponent - 1) < 0.01)
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

    @Test("En claro, el acento y los colores de estado se leen también sobre una tarjeta, con el mouse encima")
    func onCards() {
        // El relleno de HiveCard es Color.primary al 4,5 % (7,5 % con el mouse encima); en negro puro
        // es el caso más exigente.
        for fill in [0.045, 0.075] {
            let card = HiveContrast.composite(NSColor.black.withAlphaComponent(fill), over: .white)
            for color in [Theme.accentNSColor, Theme.attentionNSColor, Theme.pendingNSColor] {
                let ratio = HiveContrast.ratio(HiveContrast.resolve(color, in: .aqua), on: card)
                #expect(ratio >= 4.5, "\(color) sobre la tarjeta (\(fill)): \(ratio)")
            }
        }
    }

    @Test("Relleno del acento: miel también en claro (no marrón) y su texto se lee (≥ 4,5)")
    func accentFill() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let fill = HiveContrast.resolve(Theme.accentFillNSColor, in: appearance)
            let text = HiveContrast.resolve(Theme.onAccentFillNSColor, in: appearance)
            #expect(HiveContrast.ratio(text, on: fill) >= 4.5, "\(appearance.rawValue)")
            // Miel: mucho rojo y verde, poco azul (el ámbar de texto en claro tiene rojo < 0,6).
            #expect(fill.redComponent > 0.85 && fill.greenComponent > 0.6 && fill.blueComponent < 0.3, "\(appearance.rawValue)")
        }
        // En oscuro, el relleno y el acento son el mismo miel.
        let fill = HiveContrast.resolve(Theme.accentFillNSColor, in: .darkAqua)
        let accent = HiveContrast.resolve(Theme.accentNSColor, in: .darkAqua)
        #expect(abs(fill.redComponent - accent.redComponent) < 0.01 && abs(fill.greenComponent - accent.greenComponent) < 0.01)
    }

    @Test("Texto secundario con datos, rojo, azul y «corriendo»: ≥ 4,5 sobre el fondo y sobre las tarjetas")
    func readableTokens() {
        let tokens: [(String, NSColor)] = [("secondaryText", Theme.secondaryTextNSColor), ("danger", Theme.dangerNSColor),
                                           ("info", Theme.infoNSColor), ("running", Theme.runningNSColor)]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let base = contrastBackground(appearance)
            // La tarjeta: el fondo con Color.primary al 4,5 % (7,5 % con el mouse encima).
            let primary: NSColor = appearance == .aqua ? .black : .white
            let backgrounds = [base] + [0.045, 0.075].map { HiveContrast.composite(primary.withAlphaComponent($0), over: base) }
            for (name, token) in tokens {
                for background in backgrounds {
                    let ratio = HiveContrast.ratio(HiveContrast.resolve(token, in: appearance), on: background)
                    #expect(ratio >= 4.5, "\(name) en \(appearance.rawValue): \(ratio)")
                }
            }
        }
        // El gris terciario del sistema no llega: por eso los datos usan secondaryText.
        #expect(contrastRatio(.tertiaryLabelColor, .aqua) < 4.5)
    }

    @Test("El verde y el naranja quedan para las sesiones: comandos, errores y uso alto usan otros colores")
    func reservedStatusColors() {
        func same(_ a: NSColor, _ b: NSColor, _ appearance: NSAppearance.Name) -> Bool {
            let x = HiveContrast.resolve(a, in: appearance), y = HiveContrast.resolve(b, in: appearance)
            return abs(x.redComponent - y.redComponent) < 0.08 && abs(x.greenComponent - y.greenComponent) < 0.08
                && abs(x.blueComponent - y.blueComponent) < 0.08
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for other in [Theme.runningNSColor, Theme.dangerNSColor, Theme.infoNSColor] {
                #expect(!same(other, Theme.pendingNSColor, appearance), "\(other) parece el verde de «te espera»")
                #expect(!same(other, Theme.attentionNSColor, appearance), "\(other) parece el naranja de permiso")
            }
            // El uso alto: miel hasta 95 % y rojo después, nunca el naranja de permiso.
            for percent in [50.0, 85, 97] {
                let color = NSColor(UsageMonitor.color(percent))
                #expect(!same(color, Theme.attentionNSColor, appearance), "\(percent) %")
            }
            #expect(same(NSColor(UsageMonitor.color(85)), Theme.accentNSColor, appearance))
            #expect(same(NSColor(UsageMonitor.color(97)), Theme.dangerNSColor, appearance))
        }
    }

    /// Los archivos de HiveKit que dibujan estados de sesión (o definen los colores): los únicos que
    /// pueden usar el naranja de permiso y el verde de «te espera».
    static let statusColorFiles: Set<String> = ["DesignSystem.swift", "StatusStyle.swift", "SessionCards.swift",
                                                "SidebarView.swift", "CompactLayout.swift", "Appearance.swift"]

    @Test("En el código, el naranja y el verde de estado solo aparecen donde se dibujan sesiones, y no quedan colores del sistema")
    func reservedStatusColorsInSource() throws {
        // Tests/HiveKitTests/ContrastTests.swift → la raíz del paquete.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("Sources/HiveKit")
        let files = try #require(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "LogoAssets.swift" })
        #expect(files.count > 20)
        let status = try NSRegularExpression(pattern: #"Theme\.(attention|pending)"#)
        // `.red`, `Color.green`, `NSColor.systemOrange`…: no se adaptan al modo claro y se confunden con los estados.
        let system = try NSRegularExpression(pattern: #"(Color\.|\(\.|: \.|\? \.)(red|green|blue|orange|yellow)\b|\.system(Red|Green|Blue|Orange|Yellow)\b"#)
        for file in files {
            let name = file.lastPathComponent
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let range = NSRange(line.startIndex..., in: line)
                if !Self.statusColorFiles.contains(name) {
                    #expect(status.firstMatch(in: line, range: range) == nil,
                            "\(name):\(index + 1) usa el color de un estado de sesión (Theme.attention o Theme.pending): usá danger, info, running o el acento")
                }
                if name != "DesignSystem.swift" {
                    #expect(system.firstMatch(in: line, range: range) == nil, "\(name):\(index + 1) usa un color del sistema: usá un token de Theme")
                }
            }
        }
    }

    @Test("El botón principal de cada hoja (el de Return) es el miel de Hive, no el botón por defecto del sistema")
    func defaultButtonsUseAccentFill() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("Sources/HiveKit"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
        var found = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".keyboardShortcut(.defaultAction)") {
                found += 1
                let before = lines[max(0, index - 3)..<index].joined(separator: "\n")
                #expect(before.contains(".buttonStyle(.hiveProminent)"),
                        "\(file.lastPathComponent):\(index + 1): el botón de Return va con .buttonStyle(.hiveProminent) (miel con texto oscuro)")
            }
        }
        #expect(found >= 5)
    }

    @Test("Color.honey es el acento del tema: cambia con la apariencia")
    func honeyIsAccent() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let honey = HiveContrast.resolve(NSColor(Color.honey), in: appearance)
            let accent = HiveContrast.resolve(Theme.accentNSColor, in: appearance)
            #expect(abs(honey.redComponent - accent.redComponent) < 0.01, "\(appearance.rawValue)")
            #expect(abs(honey.greenComponent - accent.greenComponent) < 0.01, "\(appearance.rawValue)")
            #expect(abs(honey.blueComponent - accent.blueComponent) < 0.01, "\(appearance.rawValue)")
        }
        // En claro ya no es el miel de oscuro: es el ámbar que se lee sobre blanco.
        let light = HiveContrast.resolve(NSColor(Color.honey), in: .aqua)
        #expect(light.redComponent < 0.7)
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
