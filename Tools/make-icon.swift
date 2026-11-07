// Renders the FnVoice app icon: the dictation capsule with its 5-bar waveform on a macOS
// rounded-square ("squircle") background. Run via `make icon`; writes Resources/AppIcon.icns.
//
//   swift Tools/make-icon.swift <output-dir>
import AppKit

let canvas: CGFloat = 1024

func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
// Palette from traditional Chinese colours: 靛蓝 body, a deeper indigo capsule, 象牙白 bars.
let env = ProcessInfo.processInfo.environment
let background = hex(UInt32(env["ICON_BG"] ?? "065279", radix: 16)!)
let capsuleFill = hex(UInt32(env["ICON_CAPSULE"] ?? "033A57", radix: 16)!)
let bars = hex(0xFFFBF0)

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

    // Flat background in 靛蓝 (indigo, #065279), a traditional Chinese colour; no gradient or sheen.
    ctx.addPath(bodyPath)
    ctx.setFillColor(background)
    ctx.fillPath()

    // The HUD capsule: a flat, darker shade of the background.
    let capsule = CGRect(x: body.midX - 310, y: body.midY - 130, width: 620, height: 260)
    ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: 130, cornerHeight: 130, transform: nil))
    ctx.setFillColor(capsuleFill)
    ctx.fillPath()

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
    ctx.setFillColor(bars)
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
