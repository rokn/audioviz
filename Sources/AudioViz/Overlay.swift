import AppKit
import SwiftUI

/// A connected display, identified by a name that is stable across launches.
struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let hasNotch: Bool
    let isPrimary: Bool
    let size: CGSize

    /// Current screens with stable keys; identical monitors are numbered left to right.
    static func current() -> [(info: DisplayInfo, screen: NSScreen)] {
        let primary = NSScreen.screens.first
        var seen: [String: Int] = [:]
        return NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }.map { screen in
            let name = screen.localizedName
            seen[name, default: 0] += 1
            let key = seen[name]! > 1 ? "\(name) (\(seen[name]!))" : name
            let info = DisplayInfo(id: key, hasNotch: screen.safeAreaInsets.top > 0, isPrimary: screen == primary,
                                   size: screen.frame.size)
            return (info, screen)
        }
    }
}

/// Per-notch smoothing state, carried between frames.
final class NotchState {
    var energy: Float = 0
    var lastTime: Double?
    /// Slowly decaying peaks, so the notch scales to the music's own loudness rather than absolute level.
    var energyPeak: Float = 0.08
    var levelPeak: Float = 0.15
}

/// Set while the desktop visualizer is showing on the panel's display: the panel fades out and stops rendering.
@Observable
final class Suppression {
    var active = false
}

/// Borderless panel that macOS may place over the menu bar (normal windows get pushed below it).
final class OverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Spectrum slice an edge panel shows when an edge spans several displays. Read every frame.
final class SpanState {
    var offset: CGFloat = 0
    var total: CGFloat?
}

/// Manages the transparent, click-through panels that draw the visualizer on screen edges / around the notch.
final class OverlayController {
    private enum Kind: Equatable {
        case edge(OverlayEdge)
        case notch(CGSize)
    }

    private struct Wanted {
        var kind: Kind
        var frame: NSRect
        var span = (offset: CGFloat(0), total: CGFloat?.none)
        var behindMenuBar = false
        var screen = NSRect.zero
    }

    /// Just under the menu bar's own window: above every app window, but menu titles and status icons draw on top.
    private static let behindMenuBarLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)

    private weak var model: AppModel?
    private var panels: [(kind: Kind, panel: NSPanel, span: SpanState, screen: NSRect, suppression: Suppression)] = []
    private var suppressedScreens: [NSRect] = []
    private var screenObserver: Any?

    init(model: AppModel) {
        self.model = model
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
    }

    /// Creates, moves or removes panels to match the current overlay settings and connected displays.
    func sync() {
        guard let model else { return }
        let displays = DisplayInfo.current()
        let infos = displays.map(\.info)
        if model.displays != infos { model.displays = infos }

        let o = model.params.overlay
        let wanted = o.enabled ? layout(o, displays) : []

        if wanted.map(\.kind) == panels.map(\.kind) {
            for (i, w) in wanted.enumerated() {
                if panels[i].panel.frame != w.frame { panels[i].panel.setFrame(w.frame, display: true) }
                panels[i].span.offset = w.span.offset
                panels[i].span.total = w.span.total
                panels[i].panel.level = w.behindMenuBar ? Self.behindMenuBarLevel : .statusBar
                panels[i].screen = w.screen
            }
            applySuppression()
            return
        }
        panels.forEach { $0.panel.close() }
        panels = wanted.map { w in
            let span = SpanState()
            span.offset = w.span.offset
            span.total = w.span.total
            let suppression = Suppression()
            let panel = makePanel(w.kind, frame: w.frame, span: span, suppression: suppression, model: model)
            panel.level = w.behindMenuBar ? Self.behindMenuBarLevel : .statusBar
            return (w.kind, panel, span, w.screen, suppression)
        }
        applySuppression()
    }

    /// Hides overlay panels on displays where the desktop visualizer is currently showing.
    func suppress(on screens: [NSRect]) {
        guard screens != suppressedScreens else { return }
        suppressedScreens = screens
        applySuppression()
    }

    private func applySuppression() {
        for p in panels {
            let hide = suppressedScreens.contains(p.screen)
            guard hide != p.suppression.active else { continue }
            p.suppression.active = hide
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                p.panel.animator().alphaValue = hide ? 0 : 1
            }
        }
    }

    private func layout(_ o: OverlayParams, _ displays: [(info: DisplayInfo, screen: NSScreen)]) -> [Wanted] {
        let thickness = CGFloat(o.thickness)
        let allFrames = displays.map(\.screen.frame)
        var result: [Wanted] = []

        for (info, screen) in displays {
            let config = o.config(for: info)
            guard config.enabled else { continue }
            let placement = config.placement ?? o.placement

            if placement == .notch {
                let notch = notchRect(screen)
                // Room for the glow's maximum reach plus its blur.
                let margin = CGFloat(o.notchSoftness) * 2 + 30
                let w = notch.width + CGFloat(o.notchSpread) * 2.6 + margin * 2
                let h = notch.height + CGFloat(o.notchDepth) * 1.3 + margin
                result.append(Wanted(kind: .notch(notch.size), frame: NSRect(x: notch.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h),
                                     behindMenuBar: o.behindMenuBar, screen: screen.frame))
                continue
            }

            let f = screen.frame
            let top = screen.visibleFrame.maxY // below the menu bar
            let menuBarHeight = Self.menuBarHeight(on: screen) ?? max(f.maxY - top, screen.safeAreaInsets.top, 24)
            for edge in placement.edges {
                if o.skipSharedEdges, Self.touchesOtherDisplay(edge, of: f, among: allFrames) { continue }
                let horizontal = f.width * CGFloat(o.length)
                let vertical = (top - f.minY) * CGFloat(o.length)
                let frame: NSRect = switch edge {
                case .bottom: NSRect(x: f.midX - horizontal / 2, y: f.minY, width: horizontal, height: thickness)
                case .top where o.behindMenuBar:
                    // From the very top edge so the menu bar sits over the strip's base.
                    NSRect(x: f.midX - horizontal / 2, y: f.maxY - (o.menuBarOnly ? menuBarHeight : thickness),
                           width: horizontal, height: o.menuBarOnly ? menuBarHeight : thickness)
                case .top: NSRect(x: f.midX - horizontal / 2, y: top - thickness, width: horizontal, height: thickness)
                case .left: NSRect(x: f.minX, y: f.minY + (top - f.minY - vertical) / 2, width: thickness, height: vertical)
                case .right: NSRect(x: f.maxX - thickness, y: f.minY + (top - f.minY - vertical) / 2, width: thickness, height: vertical)
                }
                result.append(Wanted(kind: .edge(edge), frame: frame, behindMenuBar: edge == .top && o.behindMenuBar,
                                     screen: f))
            }
        }

        if o.spanDisplays { assignSpans(&result) }
        return result
    }

    /// Makes same-side edge panels on different displays show consecutive slices of one long spectrum.
    private func assignSpans(_ panels: inout [Wanted]) {
        for edge in [OverlayEdge.top, .bottom, .left, .right] {
            let vertical = edge == .left || edge == .right
            // Edge-local `u` runs left→right for top/bottom and bottom→top for the sides.
            let indices = panels.indices
                .filter { panels[$0].kind == .edge(edge) }
                .sorted { vertical ? panels[$0].frame.minY < panels[$1].frame.minY : panels[$0].frame.minX < panels[$1].frame.minX }
            guard indices.count > 1 else { continue }
            let lengths = indices.map { vertical ? panels[$0].frame.height : panels[$0].frame.width }
            let total = lengths.reduce(0, +)
            var offset: CGFloat = 0
            for (i, index) in indices.enumerated() {
                panels[index].span = (offset, total)
                offset += lengths[i]
            }
        }
    }

    /// Height of the menu bar window on `screen`, measured from the window list (some displays don't report it
    /// through `visibleFrame`, e.g. when the menu bar overlaps content).
    private static func menuBarHeight(on screen: NSScreen) -> CGFloat? {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let cgTop = primary.frame.maxY - screen.frame.maxY // window list uses top-left origin
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        for w in windows where (w[kCGWindowLayer as String] as? Int) == menuLevel {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict),
                  abs(b.minX - screen.frame.minX) < 1, abs(b.minY - cgTop) < 1 else { continue }
            return b.height
        }
        return nil
    }

    /// Whether another display sits flush against this edge (e.g. the inner edges of side-by-side monitors).
    private static func touchesOtherDisplay(_ edge: OverlayEdge, of f: NSRect, among frames: [NSRect]) -> Bool {
        frames.contains { o in
            guard o != f else { return false }
            let overlapX = o.minX < f.maxX - 1 && o.maxX > f.minX + 1
            let overlapY = o.minY < f.maxY - 1 && o.maxY > f.minY + 1
            return switch edge {
            case .left: abs(o.maxX - f.minX) < 2 && overlapY
            case .right: abs(o.minX - f.maxX) < 2 && overlapY
            case .bottom: abs(o.maxY - f.minY) < 2 && overlapX
            case .top: abs(o.minY - f.maxY) < 2 && overlapX
            }
        }
    }

    /// The notch in global coordinates, or a notch-sized area at the top centre of screens without one.
    private func notchRect(_ screen: NSScreen) -> NSRect {
        let f = screen.frame
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NSRect(x: f.minX + left.width, y: f.maxY - inset, width: f.width - left.width - right.width, height: inset)
        }
        let menuBar = max(f.maxY - screen.visibleFrame.maxY, 24)
        return NSRect(x: f.midX - 100, y: f.maxY - menuBar, width: 200, height: menuBar)
    }

    private func makePanel(_ kind: Kind, frame: NSRect, span: SpanState, suppression: Suppression, model: AppModel) -> NSPanel {
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let root: AnyView = switch kind {
        case let .edge(edge): AnyView(OverlayEdgeView(model: model, edge: edge, span: span, suppression: suppression))
        case let .notch(size): AnyView(OverlayNotchView(model: model, notch: size, state: NotchState(), suppression: suppression))
        }
        let host = NSHostingView(rootView: root.ignoresSafeArea())
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }
}

private struct OverlayEdgeView: View {
    let model: AppModel
    let edge: OverlayEdge
    let span: SpanState
    let suppression: Suppression

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: suppression.active)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                model.tick(t)
                OverlayRenderer.drawEdge(&ctx, size: size, edge: edge, a: model.analyzer, p: model.params, time: t,
                                         spanOffset: span.offset, spanTotal: span.total)
            }
        }
    }
}

private struct OverlayNotchView: View {
    let model: AppModel
    let notch: CGSize
    let state: NotchState
    let suppression: Suppression

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: suppression.active)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                model.tick(t)
                OverlayRenderer.drawNotch(&ctx, size: size, notch: notch, state: state, a: model.analyzer, p: model.params, time: t)
            }
        }
    }
}

enum OverlayRenderer {
    /// Draws in edge-local coordinates: `u` runs along the edge, `v` grows inward from it.
    /// With `spanTotal`, the panel shows the slice starting at `spanOffset` of a spectrum `spanTotal` long.
    static func drawEdge(_ ctx: inout GraphicsContext, size: CGSize, edge: OverlayEdge, a: Analyzer, p: VizParams, time: Double,
                         spanOffset: CGFloat = 0, spanTotal: CGFloat? = nil) {
        guard !a.levels.isEmpty else { return }
        let vertical = edge == .left || edge == .right
        let length = vertical ? size.height : size.width
        let depth = vertical ? size.width : size.height
        let transform: CGAffineTransform = switch edge {
        case .top: .identity
        case .bottom: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: depth)
        case .left: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: length)
        case .right: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: depth, ty: length)
        }
        ctx.concatenate(transform)
        ctx.translateBy(x: -spanOffset, y: 0)
        ctx.opacity = p.overlay.opacity

        let strip = Strip(a: a, p: p, time: time, length: spanTotal ?? length, depth: depth)
        if p.overlay.style == .glow {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: depth * 0.18))
                strip.wave(layer, fillOpacity: 0.9, stroke: false)
            }
            return
        }
        if p.glow > 0 {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 10))
                layer.opacity = p.glow
                strip.draw(layer)
            }
        }
        strip.draw(ctx)
    }

    static func drawNotch(_ ctx: inout GraphicsContext, size: CGSize, notch: CGSize, state: NotchState,
                          a: Analyzer, p: VizParams, time: Double) {
        let n = a.levels.count
        guard n > 0 else { return }
        let o = p.overlay

        // Bands the notch listens to (falls back to everything if the range is outside the analyzed spectrum).
        let picked = a.bandCenters.indices.filter { o.notchSource.range.contains(a.bandCenters[$0]) }
        let bands = picked.isEmpty ? Array(0..<n) : picked
        let raw = bands.reduce(Float(0)) { $0 + a.levels[$1] } / Float(bands.count)

        // Extra smoothing of the notch's own size, with a slower release so it settles calmly.
        let dt = Float(min(max(time - (state.lastTime ?? time), 0), 0.1))
        state.lastTime = time
        let tau = Float(o.notchSmoothing) * (raw > state.energy ? 1 : 3)
        state.energy += (raw - state.energy) * (tau < 0.001 ? 1 : 1 - exp(-dt / tau))
        let peakDecay = 1 - exp(-dt / 6)
        state.energyPeak = max(0.08, state.energy > state.energyPeak ? state.energy : state.energyPeak + (state.energy - state.energyPeak) * peakDecay)
        let frameMax = bands.map { a.levels[$0] }.max() ?? 0
        state.levelPeak = max(0.15, frameMax > state.levelPeak ? frameMax : state.levelPeak + (frameMax - state.levelPeak) * peakDecay)
        let normEnergy = CGFloat(min(1, state.energy / state.energyPeak))

        let beat = CGFloat(a.beat) * o.notchBeat
        let grow = min(1.2, normEnergy * o.notchReactivity + beat * 0.3)
        let spread = CGFloat(o.notchSpread)
        let maxDepth = CGFloat(o.notchDepth)
        let cx = size.width / 2 + CGFloat(o.notchNudgeX)
        let drift = p.hueDrift * time / 60
        let alpha = o.opacity

        func level(_ pos: Double) -> Double { // pos 0 = centre/bass end … 1 = far end
            Double(a.levels[bands[min(bands.count - 1, Int(pos * Double(bands.count)))]])
        }
        func tint(_ pos: Double, _ level: Double) -> Color {
            if o.notchMono { return .white.opacity(0.3 + 0.7 * level) }
            let band = bands[min(bands.count - 1, Int(pos * Double(bands.count)))]
            return color(p.palette.rgb(t: Double(band) / Double(max(n - 1, 1)), level: level, drift: drift))
        }
        func glow(_ path: Path, width: CGFloat? = nil, shading: GraphicsContext.Shading, amount: Double) {
            guard o.notchGlow > 0, amount > 0 else { return }
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 8))
                layer.opacity = alpha * o.notchGlow * amount
                if let width { layer.stroke(path, with: shading, lineWidth: width) } else { layer.fill(path, with: shading) }
            }
        }

        switch o.notchStyle {
        case .island, .breathe:
            let width = notch.width + 2 * spread * grow
            let depth = maxDepth * grow
            let x0 = cx - width / 2
            let radius = min(12, depth / 2 + 8)
            var island = Path(roundedRect: CGRect(x: x0, y: -radius, width: width, height: notch.height + depth + radius),
                              cornerRadii: RectangleCornerRadii(bottomLeading: radius, bottomTrailing: radius))
            // Concave flares where the island meets the top edge, like the hardware notch; they fade in as it grows.
            let flare = 8 * min(1, grow * 2)
            if flare > 0.5 {
                for (edge, dir) in [(x0, CGFloat(-1)), (x0 + width, CGFloat(1))] {
                    island.move(to: CGPoint(x: edge + dir * flare, y: 0))
                    island.addLine(to: CGPoint(x: edge, y: 0))
                    island.addLine(to: CGPoint(x: edge, y: flare))
                    island.addQuadCurve(to: CGPoint(x: edge + dir * flare, y: 0), control: CGPoint(x: edge, y: 0))
                }
            }
            let accent = o.notchMono ? Color.white : color(p.palette.rgb(t: 0.15, level: 1, drift: drift))
            glow(island, shading: .color(accent), amount: Double(0.2 + 0.8 * grow))
            ctx.fill(island, with: .color(.black))

            guard o.notchStyle == .island else { return }
            let inner = CGRect(x: x0 + radius * 0.6, y: notch.height + 3, width: width - radius * 1.2, height: max(0, depth - 8))
            guard inner.height > 3, inner.width > 10 else { return }
            let slots = max(2, min(o.notchBars, Int(inner.width / 3)))
            let slotW = inner.width / CGFloat(slots)
            let barW = max(1, slotW * (1 - p.barGap))
            var bars = ctx
            bars.opacity = alpha
            bars.clip(to: island)
            for k in 0..<slots {
                let pos = abs((Double(k) + 0.5) / Double(slots) * 2 - 1)
                let v = level(pos)
                let h = max(1.5, CGFloat(v) * inner.height)
                let r = CGRect(x: inner.minX + CGFloat(k) * slotW + (slotW - barW) / 2, y: inner.midY - h / 2, width: barW, height: h)
                bars.fill(Path(roundedRect: r, cornerRadius: min(barW / 2, 2)), with: .color(tint(pos, v)))
            }

        case .aura, .halo:
            let peak = Double(state.levelPeak)
            drawGlow(ctx, ring: o.notchStyle == .halo, notch: notch, cx: cx, grow: grow, beat: beat, time: time, o: o,
                     level: { min(1, level($0) / peak) }, tint: tint)

        case .underline:
            let count = max(2, o.notchBars)
            let width = notch.width * 0.7 + 2 * spread * grow
            let segW = width / CGFloat(count)
            let y = notch.height + 4
            let height = 2 + beat * 1.5
            var line = ctx
            line.opacity = alpha
            for k in 0..<count {
                let pos = abs((Double(k) + 0.5) / Double(count) * 2 - 1)
                let v = level(pos)
                let r = CGRect(x: cx - width / 2 + CGFloat(k) * segW, y: y, width: segW + 0.5, height: height)
                glow(Path(r), shading: .color(tint(pos, v)), amount: v)
                line.fill(Path(roundedRect: r, cornerRadius: height / 2), with: .color(tint(pos, v).opacity(0.15 + 0.85 * v)))
            }

        case .dots:
            let count = max(2, o.notchBars)
            let width = notch.width + 2 * spread
            let step = width / CGFloat(count)
            let maxR = min(step * 0.45, 1 + maxDepth / 16)
            let y = notch.height + 4 + maxR
            var dots = ctx
            dots.opacity = alpha
            for k in 0..<count {
                let pos = abs((Double(k) + 0.5) / Double(count) * 2 - 1)
                let v = level(pos) * Double(min(1.3, 0.3 + o.notchReactivity))
                let r = 0.8 + maxR * CGFloat(min(1, v))
                let x = cx - width / 2 + (CGFloat(k) + 0.5) * step
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                glow(dot, shading: .color(tint(pos, v)), amount: v)
                dots.fill(dot, with: .color(tint(pos, v).opacity(0.25 + 0.75 * min(1, v))))
            }

        case .wings:
            let perSide = max(1, o.notchBars / 2)
            let slotW = spread / CGFloat(perSide)
            let barW = max(1, slotW * (1 - p.barGap))
            let maxH = max(2, notch.height - 10)
            var bars = ctx
            bars.opacity = alpha
            for k in 0..<perSide {
                let pos = (Double(k) + 0.5) / Double(perSide)
                let v = min(1, level(pos) * Double(0.3 + o.notchReactivity) + Double(beat) * 0.15)
                let h = max(1.5, CGFloat(v) * maxH)
                let offset = 6 + CGFloat(k) * slotW
                for x in [cx - notch.width / 2 - offset - barW, cx + notch.width / 2 + offset] {
                    let r = CGRect(x: x, y: notch.height / 2 - h / 2, width: barW, height: h)
                    let path = Path(roundedRect: r, cornerRadius: min(barW / 2, 1.5))
                    glow(path, shading: .color(tint(pos, v)), amount: v)
                    bars.fill(path, with: .color(tint(pos, v)))
                }
            }
        }
    }

    /// Wavy outlines that start inside the notch (where there are no pixels) and reach outward, with a mirrored
    /// palette gradient. Aura fills nested outlines into a soft glow; Halo strokes the outer one as a glowing ring.
    private static func drawGlow(_ ctx: GraphicsContext, ring: Bool, notch: CGSize, cx: CGFloat, grow: CGFloat, beat: CGFloat,
                                 time: Double, o: OverlayParams, level: (Double) -> Double, tint: (Double, Double) -> Color) {
        let hSpread = CGFloat(o.notchSpread), vSpread = CGFloat(o.notchDepth)
        let halfW = notch.width / 2 - 6, innerH = notch.height - 6 // start just inside the notch
        let steps = 140
        let exponent = 2.0 / 5.0 // superellipse: close to the notch's rounded-rectangle shape

        // Outward reach (0…~1.2) at each point; θ runs 0 (right, top edge) → π/2 (bottom) → π (left, top edge).
        let rawReach: [CGFloat] = (0...steps).map { i in
            let theta = Double.pi * Double(i) / Double(steps)
            let pos = abs(theta - .pi / 2) / (.pi / 2) // 0 = bottom centre (bass) … 1 = sides (treble)
            let ripple = sin(theta * 6 + time * 1.3) * 0.55 + sin(theta * 11 - time * 0.8) * 0.3 + sin(theta * 3 - time * 0.5) * 0.15
            let dynamic = min(1.2, Double(grow) * 0.5 + level(pos) * o.notchReactivity * 0.6 + Double(beat) * 0.3)
            let r = o.notchBase + (1 - o.notchBase) * dynamic
            return CGFloat(max(0, min(1.3, r * (1 + o.notchWave * ripple * 0.5))))
        }
        // Moving average so neighbouring bands blend into smooth waves instead of spikes.
        let window = 8
        let reach: [CGFloat] = rawReach.indices.map { i in
            let lo = max(0, i - window), hi = min(steps, i + window)
            return rawReach[lo...hi].reduce(0, +) / CGFloat(hi - lo + 1)
        }

        func shape(_ scale: CGFloat) -> Path {
            var path = Path()
            for i in 0...steps {
                let theta = Double.pi * Double(i) / Double(steps)
                let c = cos(theta), s = sin(theta)
                let ex = CGFloat(copysign(pow(abs(c), exponent), c)), ey = CGFloat(pow(s, exponent))
                let r = reach[i] * scale
                let pt = CGPoint(x: cx + ex * (halfW + hSpread * r), y: ey * (innerH + vSpread * r))
                if i == 0 { path.move(to: CGPoint(x: pt.x, y: -2)) }
                path.addLine(to: pt)
            }
            path.addLine(to: CGPoint(x: cx - halfW - hSpread * reach[steps] * scale, y: -2))
            path.closeSubpath()
            return path
        }

        let extent = notch.width / 2 + hSpread
        let gradient = GraphicsContext.Shading.linearGradient(
            Gradient(colors: (0...10).map { i in
                let pos = abs(Double(i) / 10 * 2 - 1)
                return tint(pos, max(0.7, level(pos)))
            }),
            startPoint: CGPoint(x: cx - extent, y: 0), endPoint: CGPoint(x: cx + extent, y: 0))

        let softness = CGFloat(o.notchSoftness)
        if ring {
            let outline = shape(1)
            let width = 1.5 + 2 * grow
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: softness))
                layer.opacity = o.opacity
                var fill = layer
                fill.opacity = 0.18
                fill.fill(outline, with: gradient)
                var halo = layer
                halo.opacity = 0.5 + 0.5 * o.notchGlow
                halo.stroke(outline, with: gradient, lineWidth: width + 4 + softness * 0.6)
            }
            var line = ctx
            line.opacity = o.opacity
            line.stroke(outline, with: gradient, lineWidth: width)
            return
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: softness))
            layer.opacity = o.opacity
            for k in stride(from: 1.0, to: 0.1, by: -0.2) {
                var l = layer
                l.opacity = 0.32 + 0.2 * o.notchGlow
                l.fill(shape(CGFloat(k)), with: gradient)
            }
        }
    }

    fileprivate static func color(_ c: SIMD3<Double>) -> Color { Color(red: c.x, green: c.y, blue: c.z) }
}

/// Spectrum laid out along an edge strip, optionally mirrored so the bass sits in the middle.
private struct Strip {
    let a: Analyzer
    let p: VizParams
    let time: Double
    let length: CGFloat
    let depth: CGFloat

    private var n: Int { a.levels.count }
    private var slots: Int { p.overlay.symmetric ? 2 * n : n }
    private var slotWidth: CGFloat { length / CGFloat(slots) }
    private var pulse: CGFloat { 1 + CGFloat(a.beat) * p.beatPulse * 0.15 }

    private func band(_ slot: Int) -> Int {
        guard p.overlay.symmetric else { return slot }
        return slot < n ? n - 1 - slot : slot - n
    }

    private func value(_ slot: Int) -> CGFloat { min(1, CGFloat(a.levels[band(slot)]) * pulse) }

    private func color(_ slot: Int) -> Color {
        let b = band(slot)
        return OverlayRenderer.color(p.palette.rgb(t: Double(b) / Double(max(n - 1, 1)), level: Double(a.levels[b]),
                                                   drift: p.hueDrift * time / 60))
    }

    func draw(_ ctx: GraphicsContext) {
        switch p.overlay.style {
        case .bars: bars(ctx)
        case .wave, .glow: wave(ctx, fillOpacity: 0.35, stroke: true)
        }
    }

    func bars(_ ctx: GraphicsContext) {
        let w = max(1, slotWidth * (1 - p.barGap))
        for k in 0..<slots {
            let h = max(1, value(k) * depth)
            let u = CGFloat(k) * slotWidth + (slotWidth - w) / 2
            ctx.fill(Path(roundedRect: CGRect(x: u, y: 0, width: w, height: h), cornerRadius: min(w / 2, 3)), with: .color(color(k)))
            let pv = min(1, CGFloat(a.peaks[band(k)])) * depth
            if p.showPeaks, pv > 3 {
                ctx.fill(Path(CGRect(x: u, y: pv, width: w, height: 2)), with: .color(.white.opacity(0.7)))
            }
        }
    }

    func wave(_ ctx: GraphicsContext, fillOpacity: Double, stroke: Bool) {
        let pts = (0..<slots).map { CGPoint(x: (CGFloat($0) + 0.5) * slotWidth, y: value($0) * depth) }
        var curve = Path()
        curve.move(to: CGPoint(x: 0, y: pts[0].y))
        curve.addLine(to: pts[0])
        for i in 1..<pts.count {
            curve.addQuadCurve(to: CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2), control: pts[i - 1])
        }
        curve.addLine(to: pts[pts.count - 1])
        curve.addLine(to: CGPoint(x: length, y: pts[pts.count - 1].y))
        var fill = curve
        fill.addLine(to: CGPoint(x: length, y: 0))
        fill.addLine(to: .zero)
        fill.closeSubpath()

        let stops = stride(from: 0, to: slots, by: max(1, slots / 32)).map { color($0) }
        let start = CGPoint.zero, end = CGPoint(x: length, y: 0)
        ctx.fill(fill, with: .linearGradient(Gradient(colors: stops.map { $0.opacity(fillOpacity) }), startPoint: start, endPoint: end))
        if stroke {
            ctx.stroke(curve, with: .linearGradient(Gradient(colors: stops), startPoint: start, endPoint: end), lineWidth: 2)
        }
    }
}
