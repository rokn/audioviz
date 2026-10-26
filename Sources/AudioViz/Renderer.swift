import SwiftUI

enum Renderer {
    /// `chrome` = HUD, labels and the silence hint; `background` = opaque black fill (off to see the wallpaper through).
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, a: Analyzer, p: VizParams, time: Double,
                     chrome: Bool = true, background: Bool = true) {
        let bounds = CGRect(origin: .zero, size: size)
        if background { ctx.fill(Path(bounds), with: .color(.black)) }

        let drift = p.hueDrift * time / 60
        let n = a.levels.count
        guard n > 0 else { return }
        let colors = (0..<n).map { i in
            color(p.palette.rgb(t: Double(i) / Double(max(n - 1, 1)), level: Double(a.levels[i]), drift: drift))
        }

        // Beat flash behind everything.
        if p.beatEnabled, a.beat > 0.01, p.beatPulse > 0 {
            let c = color(p.palette.rgb(t: 0.1, level: 1, drift: drift))
            let r = max(size.width, size.height) * 0.7
            ctx.fill(Path(bounds), with: .radialGradient(
                Gradient(colors: [c.opacity(Double(a.beat) * p.beatPulse * 0.28), .clear]),
                center: CGPoint(x: size.width / 2, y: p.mode == .radial ? size.height / 2 : size.height),
                startRadius: 0, endRadius: r))
        }

        let labelSpace: CGFloat = chrome && p.showLabels && p.mode != .radial && p.mode != .waveform ? 18 : 0
        let top: CGFloat = 16 + (chrome && p.showHUD ? 22 : 0)
        let plot = CGRect(x: 16, y: top, width: size.width - 32, height: max(1, size.height - top - 16 - labelSpace))

        let content: (inout GraphicsContext) -> Void = { c in
            switch p.mode {
            case .bars: bars(c, plot, a, p, colors, mirror: false)
            case .mirror: bars(c, plot, a, p, colors, mirror: true)
            case .radial: radial(c, plot, a, p, colors)
            case .line: line(c, plot, a, p, colors)
            case .spectrogram: spectrogram(c, plot, a)
            case .waveform: waveform(c, plot, a, p, drift: drift)
            }
        }

        if p.glow > 0, p.mode != .spectrogram {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 14))
                layer.opacity = p.glow
                content(&layer)
            }
        }
        content(&ctx)

        guard chrome else { return }
        if p.showLabels { labels(ctx, plot, a, p) }
        if p.showHUD { hud(ctx, bounds, a, p) }
        if a.silentFor > 3 { silenceHint(ctx, bounds) }
    }

    // MARK: Modes

    private static func bars(_ ctx: GraphicsContext, _ rect: CGRect, _ a: Analyzer, _ p: VizParams, _ colors: [Color], mirror: Bool) {
        let n = a.levels.count
        let slot = rect.width / CGFloat(n)
        let w = max(1, slot * (1 - p.barGap))
        let pulse = 1 + CGFloat(a.beat) * p.beatPulse * 0.12
        let radius = min(w / 2, 3)
        for i in 0..<n {
            let v = min(1, CGFloat(a.levels[i]) * pulse)
            let x = rect.minX + CGFloat(i) * slot + (slot - w) / 2
            let r: CGRect
            if mirror {
                let h = max(1, v * rect.height / 2)
                r = CGRect(x: x, y: rect.midY - h, width: w, height: h * 2)
            } else {
                let h = max(1, v * rect.height)
                r = CGRect(x: x, y: rect.maxY - h, width: w, height: h)
            }
            ctx.fill(Path(roundedRect: r, cornerRadius: radius), with: .linearGradient(
                Gradient(colors: [colors[i].opacity(0.55), colors[i]]),
                startPoint: CGPoint(x: x, y: mirror ? rect.midY : rect.maxY),
                endPoint: CGPoint(x: x, y: r.minY)))

            if p.showPeaks {
                let pv = min(1, CGFloat(a.peaks[i]))
                if mirror {
                    let h = pv * rect.height / 2
                    for y in [rect.midY - h - 2, rect.midY + h] {
                        ctx.fill(Path(CGRect(x: x, y: y, width: w, height: 2)), with: .color(.white.opacity(0.75)))
                    }
                } else {
                    let y = rect.maxY - pv * rect.height - 2
                    ctx.fill(Path(CGRect(x: x, y: y, width: w, height: 2)), with: .color(.white.opacity(0.75)))
                }
            }
        }
    }

    private static func radial(_ ctx: GraphicsContext, _ rect: CGRect, _ a: Analyzer, _ p: VizParams, _ colors: [Color]) {
        let n = a.levels.count
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let side = min(rect.width, rect.height)
        let base = side * 0.2 * (1 + CGFloat(a.beat) * p.beatPulse * 0.25)
        let length = side * 0.3
        let lineWidth = max(1, (.pi * base / CGFloat(n)) * (1 - p.barGap))

        ctx.fill(Path(ellipseIn: CGRect(x: center.x - base, y: center.y - base, width: base * 2, height: base * 2)),
                 with: .radialGradient(Gradient(colors: [colors[0].opacity(0.25 + Double(a.beat) * 0.4), .clear]),
                                       center: center, startRadius: 0, endRadius: base))

        for i in 0..<n {
            let v = CGFloat(a.levels[i])
            let offset = Double.pi * (Double(i) + 0.5) / Double(n)
            for angle in [-Double.pi / 2 + offset, -Double.pi / 2 - offset] {
                let dir = CGPoint(x: cos(angle), y: sin(angle))
                var path = Path()
                path.move(to: CGPoint(x: center.x + dir.x * base, y: center.y + dir.y * base))
                let r = base + max(2, v * length)
                path.addLine(to: CGPoint(x: center.x + dir.x * r, y: center.y + dir.y * r))
                ctx.stroke(path, with: .color(colors[i]), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                if p.showPeaks {
                    let pr = base + CGFloat(a.peaks[i]) * length + lineWidth + 2
                    let dot = CGRect(x: center.x + dir.x * pr - 1.5, y: center.y + dir.y * pr - 1.5, width: 3, height: 3)
                    ctx.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.7)))
                }
            }
        }
    }

    private static func line(_ ctx: GraphicsContext, _ rect: CGRect, _ a: Analyzer, _ p: VizParams, _ colors: [Color]) {
        let n = a.levels.count
        let pts = (0..<n).map { i in
            CGPoint(x: rect.minX + rect.width * (CGFloat(i) + 0.5) / CGFloat(n),
                    y: rect.maxY - CGFloat(a.levels[i]) * rect.height)
        }
        var curve = Path()
        curve.move(to: CGPoint(x: rect.minX, y: pts[0].y))
        curve.addLine(to: pts[0])
        for i in 1..<n {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            curve.addQuadCurve(to: mid, control: pts[i - 1])
        }
        curve.addLine(to: pts[n - 1])
        curve.addLine(to: CGPoint(x: rect.maxX, y: pts[n - 1].y))

        var fill = curve
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fill.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        fill.closeSubpath()

        let stops = stride(from: 0, to: n, by: max(1, n / 24)).map { colors[$0] }
        let start = CGPoint(x: rect.minX, y: 0), end = CGPoint(x: rect.maxX, y: 0)
        ctx.fill(fill, with: .linearGradient(Gradient(colors: stops.map { $0.opacity(0.3) }), startPoint: start, endPoint: end))
        ctx.stroke(curve, with: .linearGradient(Gradient(colors: stops), startPoint: start, endPoint: end), lineWidth: 2.5)

        if p.showPeaks {
            var peaks = Path()
            for i in 0..<n {
                let pt = CGPoint(x: pts[i].x, y: rect.maxY - CGFloat(a.peaks[i]) * rect.height)
                if i == 0 { peaks.move(to: pt) } else { peaks.addLine(to: pt) }
            }
            ctx.stroke(peaks, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    private static func spectrogram(_ ctx: GraphicsContext, _ rect: CGRect, _ a: Analyzer) {
        guard let image = a.spectrogramImage() else { return }
        ctx.draw(Image(decorative: image, scale: 1), in: rect)
    }

    private static func waveform(_ ctx: GraphicsContext, _ rect: CGRect, _ a: Analyzer, _ p: VizParams, drift: Double) {
        let count = Analyzer.waveformLength / 2
        let gain = 0.9 / CGFloat(a.waveEnvelope)
        var path = Path()
        for i in 0..<count {
            let s = CGFloat(a.waveform[a.waveTrigger + i])
            let pt = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(count - 1),
                             y: rect.midY - min(max(s * gain, -1), 1) * rect.height / 2)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        let level = Double(min(1, a.levels.max() ?? 0))
        let stops = (0...8).map { color(p.palette.rgb(t: Double($0) / 8, level: max(level, 0.6), drift: drift)) }
        ctx.stroke(path, with: .linearGradient(Gradient(colors: stops), startPoint: CGPoint(x: rect.minX, y: 0),
                                               endPoint: CGPoint(x: rect.maxX, y: 0)),
                   lineWidth: 2 + CGFloat(a.beat) * p.beatPulse * 2)
    }

    // MARK: Overlays

    private static let tickFreqs: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]

    private static func labels(_ ctx: GraphicsContext, _ rect: CGRect, _ a: Analyzer, _ p: VizParams) {
        guard p.mode != .radial, p.mode != .waveform else { return }
        let lo = a.effectiveMinFreq, hi = a.effectiveMaxFreq
        for f in tickFreqs where f >= lo && f <= hi {
            // Band edges are evenly spaced on the scale, so a frequency's scale position maps straight to screen position.
            let pos = p.scale.position(of: f, lo: lo, hi: hi)
            let text = Text(formatHz(f)).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
            if p.mode == .spectrogram {
                let y = rect.maxY - rect.height * pos
                ctx.fill(Path(CGRect(x: rect.minX, y: y, width: rect.width, height: 0.5)), with: .color(.white.opacity(0.08)))
                ctx.draw(text, at: CGPoint(x: rect.minX + 3, y: y - 1), anchor: .bottomLeading)
            } else {
                let x = rect.minX + rect.width * pos
                ctx.fill(Path(CGRect(x: x, y: rect.minY, width: 0.5, height: rect.height)), with: .color(.white.opacity(0.06)))
                ctx.draw(text, at: CGPoint(x: x, y: rect.maxY + 4), anchor: .top)
            }
        }
    }

    private static func hud(_ ctx: GraphicsContext, _ bounds: CGRect, _ a: Analyzer, _ p: VizParams) {
        let binHz = a.sampleRate / Double(a.fftSize)
        let windowMS = Double(a.fftSize) / a.sampleRate * 1000
        var parts = [
            "\(Int(a.sampleRate / 1000)) kHz",
            "FFT \(a.fftSize) · \(String(format: "%.1f", binHz)) Hz/bin · \(Int(windowMS)) ms",
            "\(a.levels.count) bands \(p.scale.label.lowercased())",
            p.agcEnabled ? "AGC \(Int(a.floorDB))…\(Int(a.ceilingDB)) dB" : "range \(Int(p.floorDB))…\(Int(p.ceilingDB)) dB",
        ]
        if p.beatEnabled { parts.append(a.bpm.map { "♩ \(Int($0.rounded())) BPM" } ?? "♩ —") }
        ctx.draw(Text(parts.joined(separator: "   ")).font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.5)),
                 at: CGPoint(x: 16, y: 12), anchor: .topLeading)
        if p.beatEnabled {
            let r: CGFloat = 4 + CGFloat(a.beat) * 3
            ctx.fill(Path(ellipseIn: CGRect(x: bounds.maxX - 56 - r, y: 18 - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.15 + Double(a.beat) * 0.85)))
        }
    }

    private static func silenceHint(_ ctx: GraphicsContext, _ bounds: CGRect) {
        let text = Text("Waiting for audio…\nPlay something. If nothing shows up, allow AudioViz under\nSystem Settings › Privacy & Security › Screen & System Audio Recording.")
            .font(.system(size: 13)).foregroundColor(.white.opacity(0.55))
        ctx.draw(text, at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center)
    }

    static func formatHz(_ f: Double) -> String {
        f >= 1000 ? (f.truncatingRemainder(dividingBy: 1000) == 0 || f >= 10_000
            ? "\(Int((f / 1000).rounded()))k" : String(format: "%.1fk", f / 1000)) : "\(Int(f.rounded()))"
    }

    private static func color(_ c: SIMD3<Double>) -> Color {
        Color(red: c.x, green: c.y, blue: c.z)
    }
}
