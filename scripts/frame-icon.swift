import AppKit

// frame-icon.swift <render.png> <out.png>: places a full-bleed Icon Composer render on the macOS icon
// grid (an 824-point shape centred on a 1024 canvas) with the standard soft drop shadow.
let args = CommandLine.arguments
guard args.count == 3, let render = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: frame-icon.swift <render.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let canvas = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 20
shadow.set()
render.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
