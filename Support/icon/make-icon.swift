// Renders the AudioViz app icon. Usage: swift make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
func lerp(_ a: [CGFloat], _ b: [CGFloat], _ t: CGFloat) -> CGColor {
    color(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)
}

// macOS icon grid: 824pt squircle centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow + background gradient.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0, 0, 0, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(color(0.05, 0.04, 0.12))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0.13, 0.07, 0.28), color(0.03, 0.03, 0.10)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Soft glow in the middle.
let glow = CGGradient(colorsSpace: cs, colors: [color(0.55, 0.25, 1, 0.55), color(0.2, 0.6, 1, 0.0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: [])

// Mirrored spectrum bars: bass in the middle, falling off with gentle ripples.
let magenta: [CGFloat] = [1, 0.18, 0.72], violet: [CGFloat] = [0.58, 0.3, 1], cyan: [CGFloat] = [0.15, 0.9, 1]
let bars = 13
let slot: CGFloat = 50, barW: CGFloat = 30
let startX = 512 - CGFloat(bars) * slot / 2
for i in 0..<bars {
    let d = abs(CGFloat(i) - CGFloat(bars - 1) / 2) / (CGFloat(bars - 1) / 2) // 0 centre … 1 edge
    let h = 70 + 520 * (pow(1 - d, 1.6) * 0.85 + 0.15 * (0.5 + 0.5 * cos(d * 9)))
    let x = startX + CGFloat(i) * slot + (slot - barW) / 2
    let rect = CGRect(x: x, y: 512 - h / 2, width: barW, height: h)
    let c = d < 0.5 ? lerp(magenta, violet, d * 2) : lerp(violet, cyan, (d - 0.5) * 2)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: c.copy(alpha: 0.9))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(c)
    ctx.fillPath()
    ctx.restoreGState()

    // Bright core for a neon look.
    let core = rect.insetBy(dx: barW * 0.3, dy: barW * 0.3)
    ctx.addPath(CGPath(roundedRect: core, cornerWidth: core.width / 2, cornerHeight: core.width / 2, transform: nil))
    ctx.setFillColor(color(1, 1, 1, 0.35))
    ctx.fillPath()
}

// Thin wave line threading through the bars.
let wave = CGMutablePath()
for i in 0...200 {
    let x = 150 + CGFloat(i) / 200 * 724
    let y = 512 + sin(CGFloat(i) / 200 * .pi * 5) * 60 * sin(CGFloat(i) / 200 * .pi)
    i == 0 ? wave.move(to: CGPoint(x: x, y: y)) : wave.addLine(to: CGPoint(x: x, y: y))
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 16, color: color(1, 1, 1, 0.8))
ctx.addPath(wave)
ctx.setStrokeColor(color(1, 1, 1, 0.85))
ctx.setLineWidth(6)
ctx.setLineCap(.round)
ctx.strokePath()
ctx.restoreGState()

// Top sheen.
let sheen = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// Hairline edge.
ctx.addPath(squircle)
ctx.setStrokeColor(color(1, 1, 1, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
