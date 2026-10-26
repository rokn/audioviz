// Renders the README images with the real renderer and a synthetic track.
// Usage: swiftc -O -o /tmp/shots docs/render-screenshots.swift $(ls Sources/AudioViz/*.swift | grep -v AudioVizApp) && /tmp/shots docs

import SwiftUI

let out = CommandLine.arguments[1]
let sr = 48000.0
let ring = SampleRing()
let a = Analyzer(ring: ring)
var t = 0.0
var seed: UInt64 = 42
func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(Int64(bitPattern: seed >> 11) % 1000) / 1000 }
var hp = 0.0, lastN = 0.0

/// A little synthetic track at 124 BPM: kick, bassline, chord pad, hats.
func sample(_ x: Double) -> Double {
    let beat = 60.0 / 124, bt = x.truncatingRemainder(dividingBy: beat)
    let kickFreq: Double = 50 + 90 * exp(-bt * 30)
    let kickEnv: Double = exp(-bt * 9)
    let kick: Double = sin(2 * Double.pi * kickFreq * bt) * kickEnv * 0.9
    let notes = [55.0, 55, 65.4, 49]
    let bf = notes[Int(x / (beat * 4)) % 4]
    let b1: Double = sin(2 * Double.pi * bf * x), b2: Double = sin(4 * Double.pi * bf * x)
    let bass: Double = (b1 + 0.4 * b2) * 0.25
    var chord = 0.0
    for f in [220.0, 261.6, 329.6, 440, 523.3] {
        let c1: Double = sin(2 * Double.pi * f * x), c3: Double = sin(6 * Double.pi * f * x)
        chord += c1 + 0.3 * c3
    }
    chord *= 0.035
    let ht = (x + beat / 2).truncatingRemainder(dividingBy: beat / 2)
    let n = noise() * 2 - 1
    hp = 0.6 * (hp + n - lastN); lastN = n
    let hats: Double = hp * exp(-ht * 40) * 0.25
    let air: Double = (noise() * 2 - 1) * 0.004
    let mix: Double = kick + bass
    return mix + chord + hats + air
}

func run(_ p: VizParams, seconds: Double) {
    for _ in 0..<Int(seconds * 60) {
        var buf = [Float](repeating: 0, count: 800)
        for i in 0..<800 { buf[i] = Float(sample(t + Double(i) / sr)) }
        buf.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 800) }
        t += 800 / sr
        a.update(p, sampleRate: sr, time: t)
    }
}
/// Advance until shortly after a beat so frames look lively.
func runToBeat(_ p: VizParams) {
    run(p, seconds: 0.5)
    let beat = 60.0 / 124
    while (t.truncatingRemainder(dividingBy: beat)) > 0.06 { run(p, seconds: 1.0 / 60) }
}

@MainActor func save(_ name: String, _ w: CGFloat, _ h: CGFloat, _ view: some View) {
    let r = ImageRenderer(content: view.frame(width: w, height: h))
    r.scale = 2
    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

func viz(_ p: VizParams, chrome: Bool = true) -> some View {
    let time = t
    return Canvas { ctx, size in Renderer.draw(&ctx, size: size, a: a, p: p, time: time, chrome: chrome) }
}

MainActor.assumeIsolated {
    var p = VizParams()
    run(p, seconds: 6)

    for (name, edit) in [
        ("bars", { (q: inout VizParams) in q.mode = .bars; q.palette = .spectrum }),
        ("radial", { (q: inout VizParams) in q.mode = .radial; q.palette = .neon; q.glow = 0.9 }),
        ("mirror", { (q: inout VizParams) in q.mode = .mirror; q.palette = .fire; q.glow = 0.8 }),
        ("line", { (q: inout VizParams) in q.mode = .line; q.palette = .aurora; q.glow = 0.7 }),
    ] as [(String, (inout VizParams) -> Void)] {
        p = VizParams(); edit(&p)
        runToBeat(p)
        save(name, 960, 520, viz(p))
    }

    p = VizParams(); p.mode = .spectrogram; p.palette = .fire; p.bandCount = 128
    run(p, seconds: 11)
    save("spectrogram", 960, 520, viz(p))

    // Notch: fake menu bar over a wallpaper gradient, overlay drawn, hardware notch on top.
    let wallpaper = LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.05, green: 0.15, blue: 0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
    for (name, style) in [("notch-aura", NotchStyle.aura), ("notch-halo", .halo), ("notch-island", .island)] {
        p = VizParams(); p.overlay.notchStyle = style; p.overlay.notchSpread = 220; p.overlay.notchDepth = 90
        if style == .island { p.overlay.notchDepth = 70; p.overlay.notchBars = 40 }
        runToBeat(p)
        let state = NotchState(); state.energy = 0.42; state.energyPeak = 0.5; state.levelPeak = 0.7; state.lastTime = t
        let time = t
        save(name, 960, 240, ZStack(alignment: .top) {
            wallpaper
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 34)), with: .color(.white.opacity(0.06)))
                var c2 = ctx
                c2.translateBy(x: size.width / 2 - 400, y: 0)
                OverlayRenderer.drawNotch(&c2, size: CGSize(width: 800, height: 240), notch: CGSize(width: 190, height: 34),
                                          state: state, a: a, p: p, time: time)
                ctx.fill(Path(roundedRect: CGRect(x: size.width / 2 - 95, y: -12, width: 190, height: 46), cornerRadius: 10), with: .color(.black))
                let menu = ["", "Finder", "File", "Edit", "View", "Go", "Window"]
                var x: CGFloat = 46
                for (i, m) in menu.enumerated() where i > 0 {
                    ctx.draw(Text(m).font(.system(size: 13, weight: i == 1 ? .bold : .regular)).foregroundColor(.white), at: CGPoint(x: x, y: 17), anchor: .leading)
                    x += CGFloat(m.count) * 8 + 22
                }
                ctx.draw(Image(systemName: "apple.logo"), at: CGPoint(x: 24, y: 17))
                ctx.draw(Text("Mon 26 Oct  21:41").font(.system(size: 13)).foregroundColor(.white), at: CGPoint(x: size.width - 16, y: 17), anchor: .trailing)
            }
        })
    }

    // Bottom-edge overlay over a fake desktop.
    p = VizParams(); p.overlay.style = .bars; p.palette = .neon
    runToBeat(p)
    let time = t
    save("overlay-bottom", 960, 300, ZStack(alignment: .bottom) {
        wallpaper
        Canvas { ctx, size in
            var c = ctx
            c.translateBy(x: 0, y: size.height - 110)
            OverlayRenderer.drawEdge(&c, size: CGSize(width: size.width, height: 110), edge: .bottom, a: a, p: p, time: time)
        }
    })
}
