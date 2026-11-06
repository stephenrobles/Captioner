import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// iPhone Duo App Store screenshot, laid out like Kan Do's and Stash's framed sets: the
// WHOLE device (Apple's Duo frame, inner display, landscape) under a centered white
// San Francisco Bold headline, on Captioner's magenta-to-violet icon gradient. Usage:
//   compose-duo <W> <H> <capture.png> <out.png> <headline...>   ("\n" breaks a line)
// Bezel: Bezels/iphone-duo-inner-landscape.png (3231×2383; screen cleared at
// 129,224 2868×2024, corner radius 190; opaque device box 75,172 2976×2130).

let args = CommandLine.arguments
let W = Int(args[1])!, H = Int(args[2])!
let capturePath = args[3], outPath = args[4]
let headline = args[5...].joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n")
let bezelPath = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
    .appendingPathComponent("Bezels/iphone-duo-inner-landscape.png").path
let bezelScreen = CGRect(x: 129, y: 224, width: 2868, height: 2024)
let bezelRadius: CGFloat = 190
let deviceBox = CGRect(x: 75, y: 172, width: 2976, height: 2130)

let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high
func cg(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(H) - r.maxY, width: r.width, height: r.height) }
let w = CGFloat(W), h = CGFloat(H)

// Captioner's icon gradient, top-left to bottom-right (same stops as render-app-store-assets.swift).
let colors = [NSColor(srgbRed: 0.886, green: 0.231, blue: 0.788, alpha: 1).cgColor,
              NSColor(srgbRed: 0.290, green: 0.102, blue: 0.620, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])

// Headline: white SF Bold, centered, the same size as Stash's Duo set.
let size = h * 0.064
let font = NSFont.systemFont(ofSize: size, weight: .bold)
let para = NSMutableParagraphStyle(); para.lineSpacing = -size * 0.08; para.alignment = .center
let str = NSAttributedString(string: headline, attributes: [
    .font: font, .foregroundColor: NSColor.white, .paragraphStyle: para])
let textRect = CGRect(x: w * 0.075, y: h * 0.065, width: w * 0.85, height: h * 0.3)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let measured = str.boundingRect(with: CGSize(width: textRect.width, height: 5000), options: [.usesLineFragmentOrigin])
str.draw(with: cg(CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: measured.height)), options: [.usesLineFragmentOrigin])
NSGraphicsContext.restoreGraphicsState()

// The device fills what is left: below the headline, above a bottom margin,
// never wider than 84% of the canvas. Whole device, nothing cut off.
let bezelImg = NSImage(contentsOfFile: bezelPath)!
var br = CGRect(origin: .zero, size: bezelImg.size)
let bezel = bezelImg.cgImage(forProposedRect: &br, context: nil, hints: nil)!
let top = textRect.minY + measured.height + h * 0.045
let availableH = h - top - h * 0.055
let scale = min(availableH / deviceBox.height, (w * 0.84) / deviceBox.width)
let deviceW = deviceBox.width * scale, deviceH = deviceBox.height * scale
let deviceOrigin = CGPoint(x: (w - deviceW) / 2, y: top + (availableH - deviceH) / 2)
let bezelFrame = CGRect(x: deviceOrigin.x - deviceBox.minX * scale, y: deviceOrigin.y - deviceBox.minY * scale,
                        width: CGFloat(bezel.width) * scale, height: CGFloat(bezel.height) * scale)
let screen = CGRect(x: bezelFrame.minX + bezelScreen.minX * scale, y: bezelFrame.minY + bezelScreen.minY * scale,
                    width: bezelScreen.width * scale, height: bezelScreen.height * scale)

// Soft shadow under the device so it sits on the gradient.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.012), blur: w * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.setFillColor(NSColor.black.cgColor)
ctx.addPath(CGPath(roundedRect: cg(CGRect(x: deviceOrigin.x, y: deviceOrigin.y, width: deviceW, height: deviceH)),
                   cornerWidth: bezelRadius * scale * 1.3, cornerHeight: bezelRadius * scale * 1.3, transform: nil))
ctx.fillPath()
ctx.restoreGState()

let img = NSImage(contentsOfFile: capturePath)!
var r = CGRect(origin: .zero, size: img.size)
let capture = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: cg(screen), cornerWidth: bezelRadius * scale, cornerHeight: bezelRadius * scale, transform: nil)); ctx.clip()
let captureAspect = CGFloat(capture.width) / CGFloat(capture.height)
var drawRect = screen
if captureAspect > screen.width / screen.height {
    drawRect.size.width = screen.height * captureAspect; drawRect.origin.x = screen.midX - drawRect.width / 2
} else {
    drawRect.size.height = screen.width / captureAspect; drawRect.origin.y = screen.midY - drawRect.height / 2
}
ctx.draw(capture, in: cg(drawRect))
ctx.restoreGState()
ctx.draw(bezel, in: cg(bezelFrame))

let out = ctx.makeImage()!
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil); CGImageDestinationFinalize(dest)
print("wrote \(outPath) \(out.width)x\(out.height) device \(Int(deviceW))x\(Int(deviceH)) at \(Int(deviceOrigin.x)),\(Int(deviceOrigin.y))")
