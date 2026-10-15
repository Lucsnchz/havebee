import AppKit
import HiveCore
import SwiftUI

/// Ícono según el tipo de archivo, al estilo de los temas de íconos de VS Code.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 16

    var body: some View {
        let spec = FileIconSpec.for(path)
        Group {
            switch spec.glyph {
            case .symbol(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.1)
            case .text(let text):
                Text(text)
                    .font(.system(size: size * (text.count > 2 ? 0.46 : 0.58), weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(spec.color)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct FileIconSpec {
    enum Glyph {
        case symbol(String)
        case text(String)
    }

    let glyph: Glyph
    /// Color original del tema de íconos (pensado para fondo oscuro).
    let hex: UInt32

    private init(_ glyph: Glyph, _ hex: UInt32) {
        self.glyph = glyph
        self.hex = hex
    }

    /// El color tal cual en oscuro; en claro, oscurecido si es muy claro para leerse sobre blanco.
    var nsColor: NSColor {
        Theme.dynamicNSColor(light: Self.lightVariant(of: hex), dark: Theme.srgb(hex))
    }

    var color: Color { Color(nsColor: nsColor) }

    /// En modo claro, los colores con luminancia > 0,5 (amarillos, celestes, verdes claros) bajan
    /// el brillo a 0,62 de lo que eran: así JS, JSON o .env quedan con contraste ≥ 3 sobre blanco.
    static func lightVariant(of hex: UInt32) -> NSColor {
        let color = Theme.srgb(hex)
        guard HiveContrast.luminance(color) > 0.5 else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness * 0.62, alpha: alpha)
    }

    private static func symbol(_ name: String, _ hex: UInt32) -> FileIconSpec { FileIconSpec(.symbol(name), hex) }
    private static func text(_ text: String, _ hex: UInt32) -> FileIconSpec { FileIconSpec(.text(text), hex) }

    static func `for`(_ path: String) -> FileIconSpec {
        if path.hasSuffix("/") { return symbol("folder.fill", 0x90A4AE) }
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()

        // Nombres especiales primero.
        if lower == "dockerfile" || lower.hasPrefix("docker-compose") || lower.hasSuffix(".dockerfile") { return symbol("shippingbox.fill", 0x2496ED) }
        if lower.hasPrefix(".git") { return symbol("arrow.triangle.branch", 0xF14E32) }
        if lower == ".env" || lower.hasPrefix(".env.") { return symbol("key.fill", 0xECD53F) }
        if lower == "package.json" || lower == "package-lock.json" { return text("npm", 0xCB3837) }
        if lower == "composer.json" || lower == "composer.lock" { return text("C", 0x8F6E4C) }
        if lower.hasPrefix("readme") { return symbol("info.circle.fill", 0x519ABA) }
        if lower.hasPrefix("license") || lower.hasPrefix("licence") { return symbol("checkmark.seal.fill", 0xD0BF41) }
        if lower == "makefile" { return symbol("hammer.fill", 0xE37933) }
        if lower.hasSuffix(".blade.php") { return symbol("flame.fill", 0xF9322C) }
        if lower.hasSuffix(".d.ts") { return text("TS", 0x3178C6) }
        if lower.hasSuffix(".lock") || lower.hasSuffix("-lock.json") || lower.hasSuffix(".lockb") { return symbol("lock.fill", 0x8A8F98) }
        if lower.contains(".test.") || lower.contains(".spec.") || lower.hasSuffix("test.php") { return symbol("checkmark.circle.fill", 0x8BC34A) }

        switch (lower as NSString).pathExtension {
        case "php": return text("php", 0x8892BF)
        case "js", "mjs", "cjs": return text("JS", 0xF1DD3F)
        case "jsx": return symbol("atom", 0x61DAFB)
        case "ts", "mts", "cts": return text("TS", 0x3178C6)
        case "tsx": return symbol("atom", 0x3178C6)
        case "vue": return text("V", 0x41B883)
        case "svelte": return text("S", 0xFF3E00)
        case "astro": return symbol("sparkles", 0xFF5D01)
        case "json", "jsonc": return text("{}", 0xCBCB41)
        case "md", "mdx", "markdown": return text("M↓", 0x519ABA)
        case "css": return text("#", 0x42A5F5)
        case "scss", "sass": return text("S", 0xCD6799)
        case "less": return text("L", 0x2A4D80)
        case "html", "htm": return text("<>", 0xE44D26)
        case "xml", "plist", "xib", "storyboard": return text("<>", 0xE37933)
        case "svg": return symbol("square.on.circle", 0xFFB13B)
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "heic", "avif": return symbol("photo.fill", 0xA074C4)
        case "mp4", "mov", "webm", "avi": return symbol("film.fill", 0xFD971F)
        case "mp3", "wav", "ogg", "m4a": return symbol("waveform", 0xEE5FA7)
        case "pdf": return symbol("doc.richtext.fill", 0xE5413E)
        case "py", "pyi": return text("py", 0x4B8BBE)
        case "rb", "erb": return symbol("diamond.fill", 0xCC342D)
        case "go": return text("go", 0x00ADD8)
        case "rs": return symbol("gearshape.2.fill", 0xDEA584)
        case "swift": return symbol("swift", 0xF05138)
        case "kt", "kts": return text("K", 0xA97BFF)
        case "java", "class", "jar": return symbol("cup.and.saucer.fill", 0xE76F00)
        case "gradle": return symbol("wrench.and.screwdriver.fill", 0x5EB0B0)
        case "dart": return text("D", 0x40C4FF)
        case "c", "h": return text("C", 0x5C8DBC)
        case "cpp", "cc", "hpp", "cxx": return text("C++", 0x5C8DBC)
        case "cs": return text("C#", 0x68217A)
        case "m", "mm": return text("m", 0x438EFF)
        case "sql", "sqlite", "db": return symbol("cylinder.fill", 0xE38C00)
        case "sh", "zsh", "bash", "fish": return symbol("terminal.fill", 0x89E051)
        case "yml", "yaml": return text("yml", 0xA074C4)
        case "toml", "ini", "conf", "cfg", "properties", "editorconfig": return symbol("gearshape.fill", 0x8A8F98)
        case "csv", "tsv", "xlsx", "xls": return symbol("tablecells.fill", 0x2E9E5B)
        case "txt", "log", "text": return symbol("doc.text.fill", 0x8A8F98)
        case "zip", "gz", "tar", "rar", "7z": return symbol("doc.zipper", 0xAFB42B)
        case "ttf", "otf", "woff", "woff2": return text("Aa", 0xE53935)
        case "graphql", "gql": return symbol("point.3.connected.trianglepath.dotted", 0xE535AB)
        case "prisma": return symbol("triangle.fill", 0x5A67D8)
        case "env": return symbol("key.fill", 0xECD53F)
        default: return symbol("doc.fill", 0x8A8F98)
        }
    }
}
