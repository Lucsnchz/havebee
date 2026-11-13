// Genera Resources/AppIcon.icns y AppIcon.png: el mismo logo para la app y el selector de proyectos.
// Uso: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Hive-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Hexágono con un lado arriba y otro abajo: así las celdas se apilan en columnas rectas.
func hexagon(center: CGPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for i in 0..<6 {
        let angle = CGFloat(i) * .pi / 3
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        i == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
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
    NSGradient(starting: color(0.16, 0.16, 0.19), ending: color(0.07, 0.07, 0.09))!.draw(in: card, angle: -90)
    card.addClip()

    // Panal con una H: dos columnas de cuatro celdas y una celda en el medio, encendida. Alrededor
    // sigue el panal, apenas marcado (en los tamaños chicos no, para que la H se lea limpia).
    let r = s * 0.082
    let gap = s * 0.016
    let column = 1.5 * r + gap * 0.87
    let row = sqrt(3) * r + gap
    let origin = CGPoint(x: s / 2 - column, y: s / 2 - 1.5 * row)
    func point(_ c: CGFloat, _ k: CGFloat) -> CGPoint { CGPoint(x: origin.x + c * column, y: origin.y + k * row) }

    if size >= 64 {
        color(0.96, 0.72, 0.24, 0.1).setFill()
        let faint: [(CGFloat, CGFloat)] = [(1, 0.5), (1, 2.5), (1, -0.5), (1, 3.5)]
            + [-0.5, 0.5, 1.5, 2.5, 3.5].flatMap { k in [(-1, k), (3, k)] }
        for (c, k) in faint { hexagon(center: point(c, k), radius: r * 0.94).fill() }
    }
    let honey = NSGradient(starting: color(1.0, 0.82, 0.48), ending: color(0.94, 0.65, 0.16))!
    for c in [CGFloat(0), 2] {
        for k in 0..<4 { honey.draw(in: hexagon(center: point(c, CGFloat(k)), radius: r * 0.94), angle: -90) }
    }
    color(1.0, 0.95, 0.81).setFill()
    hexagon(center: point(1, 1.5), radius: r * 0.94).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try render(1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Ícono generado: \(output.path)" : "iconutil falló")
