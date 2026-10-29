import AppKit

// Renders the 1024x1024 app icon (dark gradient rounded square, white shield, check mark) to a PNG.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8))
    exit(2)
}

let side = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("cannot create bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let full = CGFloat(side)
let tile = NSRect(x: 100, y: 100, width: full - 200, height: full - 200)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(calibratedRed: 0.20, green: 0.27, blue: 0.45, alpha: 1),
    ending: NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1)
)?.draw(in: tilePath, angle: -90)

let shield = NSBezierPath()
shield.move(to: NSPoint(x: 512, y: 790))
shield.curve(
    to: NSPoint(x: 290, y: 700),
    controlPoint1: NSPoint(x: 440, y: 760),
    controlPoint2: NSPoint(x: 370, y: 730)
)
shield.line(to: NSPoint(x: 290, y: 520))
shield.curve(
    to: NSPoint(x: 512, y: 240),
    controlPoint1: NSPoint(x: 290, y: 390),
    controlPoint2: NSPoint(x: 390, y: 290)
)
shield.curve(
    to: NSPoint(x: 734, y: 520),
    controlPoint1: NSPoint(x: 634, y: 290),
    controlPoint2: NSPoint(x: 734, y: 390)
)
shield.line(to: NSPoint(x: 734, y: 700))
shield.curve(
    to: NSPoint(x: 512, y: 790),
    controlPoint1: NSPoint(x: 654, y: 730),
    controlPoint2: NSPoint(x: 584, y: 760)
)
shield.close()
NSColor.white.setFill()
shield.fill()

let check = NSBezierPath()
check.move(to: NSPoint(x: 420, y: 505))
check.line(to: NSPoint(x: 485, y: 440))
check.line(to: NSPoint(x: 612, y: 590))
check.lineWidth = 46
check.lineCapStyle = .round
check.lineJoinStyle = .round
NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.27, alpha: 1).setStroke()
check.stroke()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
    exit(1)
}
