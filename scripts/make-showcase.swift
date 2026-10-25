import AppKit

// make-showcase.swift <renders-dir> <icon.png> <out-dir>: the README banner, in light and dark, from
// the demo screens that `Burnish --render-previews <dir> --demo` draws. Run scripts/make-showcase.sh.
let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: make-showcase.swift <renders-dir> <icon.png> <out-dir>\n".data(using: .utf8)!)
    exit(1)
}
let renders = URL(fileURLWithPath: args[1])
let icon = NSImage(contentsOfFile: args[2])!
let outDir = URL(fileURLWithPath: args[3])

let canvas = NSSize(width: 2600, height: 1560)

func image(_ name: String) -> NSImage {
    NSImage(contentsOf: renders.appendingPathComponent(name))!
}

/// Draws a screen as a macOS window: rounded corners, a hairline edge, traffic lights and a soft shadow.
/// `cropTop` trims that fraction off the top of the screen (the popover render keeps an empty toolbar band).
func drawWindow(_ screen: NSImage, in rect: NSRect, radius: CGFloat, dark: Bool, trafficLights: Bool, cropTop: CGFloat = 0) {
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.55 : 0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.shadowBlurRadius = 70
    shadow.set()
    (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let source = NSRect(x: 0, y: 0, width: screen.size.width, height: screen.size.height * (1 - cropTop))
    screen.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    if trafficLights {
        let colors = [NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
                      NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
                      NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)]
        let d: CGFloat = 24, top = rect.maxY - 34 - d
        for (i, color) in colors.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 36 + CGFloat(i) * 40, y: top, width: d, height: d)).fill()
        }
    }
    (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)).setStroke()
    let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
    edge.lineWidth = 2
    edge.stroke()
}

func render(dark: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(origin: .zero, size: canvas)

    // Backdrop: warm, like the icon's brass, with a glow behind the header.
    let backdrop = dark
        ? NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.12, blue: 0.08, alpha: 1),
                     ending: NSColor(srgbRed: 0.08, green: 0.06, blue: 0.05, alpha: 1))!
        : NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.96, blue: 0.88, alpha: 1),
                     ending: NSColor(srgbRed: 0.97, green: 0.86, blue: 0.68, alpha: 1))!
    backdrop.draw(in: bounds, angle: -70)
    let glow = NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.74, blue: 0.30, alpha: dark ? 0.22 : 0.30),
                          ending: NSColor(srgbRed: 1.0, green: 0.74, blue: 0.30, alpha: 0))!
    glow.draw(fromCenter: NSPoint(x: 420, y: 1180), radius: 0, toCenter: NSPoint(x: 420, y: 1180), radius: 900, options: [])

    // Header: icon, name and line.
    let iconSize: CGFloat = 230
    icon.draw(in: NSRect(x: 128, y: canvas.height - 150 - iconSize, width: iconSize, height: iconSize))
    let ink = dark ? NSColor(white: 0.97, alpha: 1) : NSColor(srgbRed: 0.16, green: 0.11, blue: 0.07, alpha: 1)
    let soft = dark ? NSColor(white: 1, alpha: 0.62) : NSColor(srgbRed: 0.36, green: 0.27, blue: 0.18, alpha: 1)
    let name = NSAttributedString(string: "Burnish", attributes: [
        .font: NSFont.systemFont(ofSize: 132, weight: .bold), .foregroundColor: ink, .kern: -2.5])
    name.draw(at: NSPoint(x: 150, y: canvas.height - 560))
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = 1.08
    let line = NSAttributedString(string: "Every app on your Mac,\nkept current.", attributes: [
        .font: NSFont.systemFont(ofSize: 58, weight: .medium), .foregroundColor: soft, .paragraphStyle: paragraph])
    line.draw(in: NSRect(x: 156, y: canvas.height - 760, width: 700, height: 180))

    // The main window on the right, the menu bar popover in front of its lower left corner.
    let suffix = dark ? "-dark" : ""
    let main = image("main\(suffix).png")
    let mainWidth: CGFloat = 1640
    let mainRect = NSRect(x: canvas.width - mainWidth - 110, y: (canvas.height - mainWidth * main.size.height / main.size.width) / 2 - 10,
                          width: mainWidth, height: mainWidth * main.size.height / main.size.width)
    drawWindow(main, in: mainRect, radius: 34, dark: dark, trafficLights: true)
    let popover = image("popover\(suffix).png")
    let popWidth: CGFloat = 640
    let popCrop: CGFloat = 56 / 774
    let popRect = NSRect(x: 520, y: 110, width: popWidth, height: popWidth * popover.size.height * (1 - popCrop) / popover.size.width)
    drawWindow(popover, in: popRect, radius: 30, dark: dark, trafficLights: false, cropTop: popCrop)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for dark in [false, true] {
    let url = outDir.appendingPathComponent(dark ? "showcase-dark.png" : "showcase.png")
    try! render(dark: dark).representation(using: .png, properties: [:])!.write(to: url)
}
