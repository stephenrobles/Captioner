// Renders the Captioner app icon: a line of caption text with the active word in a highlight
// box, on a magenta-to-violet tile.
//
// Usage: swift Tools/make-icon.swift <output-dir>
// Writes icon_<size>.png for 16…1024 (rounded macOS tile with shadow) into <output-dir>.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// macOS-style continuous-corner tile (superellipse) inside the standard 824pt icon grid.
func tilePath() -> CGPath {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGMutablePath()
    let n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func fill(_ path: CGPath, in context: CGContext, gradient colors: [CGColor], locations: [CGFloat], from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip(using: .winding)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

/// Two lines of "text": rounded bars, with one bar on the top line sitting in a highlight box.
/// Returns the bars, and separately the highlight box, so they can be painted differently.
func glyph() -> (bars: [CGPath], highlight: CGPath) {
    let thickness: CGFloat = 54
    let gap: CGFloat = 40
    let lineSpacing: CGFloat = 128
    let topLineY: CGFloat = 512 + lineSpacing / 2 + 16
    let bottomLineY: CGFloat = 512 - lineSpacing / 2 + 16

    // Top line: three words, the middle one highlighted. Bottom line: two words, centered.
    let topWords: [CGFloat] = [150, 190, 170]
    let bottomWords: [CGFloat] = [230, 150]

    var bars: [CGPath] = []
    var highlight = CGPath(rect: .zero, transform: nil)

    func layout(_ words: [CGFloat], y: CGFloat, highlightIndex: Int?) {
        let total = words.reduce(0, +) + gap * CGFloat(words.count - 1)
        var x = 512 - total / 2
        for (i, width) in words.enumerated() {
            let rect = CGRect(x: x, y: y - thickness / 2, width: width, height: thickness)
            bars.append(CGPath(roundedRect: rect, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil))
            if i == highlightIndex {
                let box = rect.insetBy(dx: -26, dy: -30)
                highlight = CGPath(roundedRect: box, cornerWidth: 30, cornerHeight: 30, transform: nil)
            }
            x += width + gap
        }
    }
    layout(topWords, y: topLineY, highlightIndex: 1)
    layout(bottomWords, y: bottomLineY, highlightIndex: nil)
    return (bars, highlight)
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    context.setShouldAntialias(true)

    let tile = tilePath()

    // Drop shadow under the tile, as on system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    context.addPath(tile)
    context.setFillColor(color(0x3A1060))
    context.fillPath()
    context.restoreGState()

    // Tile: deep violet at the bottom, magenta at the top.
    fill(tile, in: context, gradient: [color(0xE23BC9), color(0x9C2BC4), color(0x4A1A9E)], locations: [0, 0.5, 1],
         from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

    // Soft glow behind the glyph.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFD1F6, 0.35), color(0xFFD1F6, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 430, options: [])
    context.restoreGState()

    let (bars, highlight) = glyph()

    // Highlight box: white, translucent, with a shadow so it sits above the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x2A0A50, 0.4))
    context.addPath(highlight)
    context.setFillColor(color(0xFFFFFF, 0.28))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(highlight)
    context.setStrokeColor(color(0xFFFFFF, 0.55))
    context.setLineWidth(6)
    context.strokePath()
    context.restoreGState()

    // Text bars: shadow, then a white → pale pink gradient.
    for path in bars {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x2A0A50, 0.45))
        context.addPath(path)
        context.setFillColor(color(0xFFFFFF))
        context.fillPath()
        context.restoreGState()
        fill(path, in: context, gradient: [color(0xFFFFFF), color(0xFFE6F8)], locations: [0, 1],
             from: CGPoint(x: 512, y: 800), to: CGPoint(x: 512, y: 224))
    }

    // Subtle inner rim on the tile.
    context.saveGState()
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: size).write(to: output.appending(path: "icon_\(size).png"))
}
print("Wrote icons to \(output.path)")
