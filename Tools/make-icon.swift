// Renders the FnVoice app icon: the dictation capsule with its 5-bar waveform on a macOS
// rounded-square ("squircle") background. Run via `make icon`; writes Resources/AppIcon.icns.
//
//   swift Tools/make-icon.swift <output-dir>
import AppKit

let canvas: CGFloat = 1024

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: 824×824 body centred on the 1024 canvas, corner radius ≈ 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow, as in Apple's template.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep indigo → violet.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.16, green: 0.12, blue: 0.48, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // Top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [
        CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // The HUD capsule.
    let capsule = CGRect(x: body.midX - 310, y: body.midY - 130, width: 620, height: 260)
    let capsulePath = CGPath(roundedRect: capsule, cornerWidth: 130, cornerHeight: 130, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(capsulePath)
    ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.06, blue: 0.22, alpha: 0.55))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(capsulePath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Waveform: the HUD's bar weights [0.5, 0.8, 1.0, 0.75, 0.55].
    let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    let barWidth: CGFloat = 50
    let gap: CGFloat = 38
    let maxHeight: CGFloat = 196
    let total = barWidth * CGFloat(weights.count) + gap * CGFloat(weights.count - 1)
    var x = capsule.midX - total / 2
    for w in weights {
        let h = maxHeight * w
        let bar = CGRect(x: x, y: capsule.midY - h / 2, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.96))
    ctx.fillPath()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: outDir.appendingPathComponent("AppIcon-1024.png"))
print("wrote \(iconset.path)")
