import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let menuChipOnly = CommandLine.arguments.contains("--menu-chip")
guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: menuChipOnly ? 600 : 1024,
    pixelsHigh: menuChipOnly ? 550 : 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: canvas) else { fatalError("앱 아이콘 캔버스 오류") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: NSRect, _ corner: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
}
func fill(_ rect: NSRect, _ corner: CGFloat, _ tint: NSColor) {
    tint.setFill()
    rounded(rect, corner).fill()
}

if menuChipOnly {
    context.cgContext.translateBy(x: -212, y: -237)
} else {
    let bounds = NSRect(x: 96, y: 96, width: 832, height: 832)
    let plate = rounded(bounds, 190)
    NSGradient(starting: color(0.16, 0.34, 0.34), ending: color(0.055, 0.10, 0.15))?.draw(in: plate, angle: -65)
    color(0.63, 0.99, 0.88, 0.25).setStroke()
    plate.lineWidth = 9
    plate.stroke()
}

let pin = color(0.44, 0.89, 0.74)
for x in [290, 390, 490, 590, 690] {
    fill(NSRect(x: x, y: 725, width: 40, height: 49), 13, pin)
    fill(NSRect(x: x, y: 250, width: 40, height: 49), 13, pin)
}
let chip = rounded(NSRect(x: 227, y: 287, width: 570, height: 450), 78)
NSGradient(starting: color(0.60, 1, 0.88), ending: color(0.27, 0.81, 0.68))?.draw(in: chip, angle: -85)
let dark = color(0.074, 0.20, 0.23)
fill(NSRect(x: 286, y: 346, width: 452, height: 332), 46, dark)
let bars = color(0.71, 1, 0.90)
fill(NSRect(x: 342, y: 401, width: 69, height: 105), 20, bars)
fill(NSRect(x: 477, y: 401, width: 69, height: 160), 20, bars)
fill(NSRect(x: 613, y: 401, width: 69, height: 222), 20, bars)
NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else { fatalError("앱 아이콘 PNG 오류") }
try png.write(to: output)
