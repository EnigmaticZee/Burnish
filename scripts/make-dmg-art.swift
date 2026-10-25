import AppKit

// make-dmg-art.swift <out-dir>: the DMG window's background, App/dmg-background.png and @2x.
// 660 x 412 points: the window in scripts/dmg-settings.py minus its title bar. The arrow runs
// between the icon centres set there, (170, 190) and (490, 190), measured from the top left.
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 660, height: 412)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Warm cream, like the icon's brass in daylight.
    NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.97, blue: 0.91, alpha: 1),
               ending: NSColor(srgbRed: 0.97, green: 0.89, blue: 0.74, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // A soft arrow from the app to Applications. y is flipped: 190 from the top.
    let y = size.height - 190
    let ink = NSColor(srgbRed: 0.69, green: 0.45, blue: 0.20, alpha: 0.55)
    ink.setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 258, y: y + 6))
    shaft.curve(to: NSPoint(x: 398, y: y + 6), controlPoint1: NSPoint(x: 300, y: y + 30), controlPoint2: NSPoint(x: 356, y: y + 30))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 382, y: y + 22))
    head.line(to: NSPoint(x: 400, y: y + 5))
    head.line(to: NSPoint(x: 377, y: y - 1))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // The one instruction, under the icons and their labels.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    NSAttributedString(string: "Drag Burnish into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.36, green: 0.25, blue: 0.14, alpha: 1),
        .paragraphStyle: style,
    ]).draw(in: NSRect(x: 0, y: 56, width: size.width, height: 24))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: outDir.appendingPathComponent("dmg-background.png"))
try! render(scale: 2).write(to: outDir.appendingPathComponent("dmg-background@2x.png"))
