// Genera Resources/AppIcon.icns: un hexágono color miel sobre fondo oscuro.
// Uso: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Hive-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func hexagon(center: CGPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for i in 0..<6 {
        let angle = CGFloat(i) * .pi / 3 + .pi / 6
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        i == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Fondo: cuadrado redondeado estilo macOS.
    let inset = s * 0.1
    let card = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2),
                            xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1))!.draw(in: card, angle: -90)

    // Panal: un hexágono central y seis alrededor, más tenues.
    let honey = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.24, alpha: 1)
    let center = CGPoint(x: s / 2, y: s / 2)
    let r = s * 0.12
    let step = r * sqrt(3) * 1.08
    for i in 0..<6 {
        let angle = CGFloat(i) * .pi / 3
        let c = CGPoint(x: center.x + step * cos(angle), y: center.y + step * sin(angle))
        honey.withAlphaComponent(i % 2 == 0 ? 0.55 : 0.3).setFill()
        hexagon(center: c, radius: r * 0.92).fill()
    }
    honey.setFill()
    hexagon(center: center, radius: r * 1.05).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Ícono generado: \(output.path)" : "iconutil falló")
