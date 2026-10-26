import Foundation

enum FrequencyScale: String, Codable, CaseIterable, Identifiable {
    case linear, log, mel, bark
    var id: Self { self }

    var label: String {
        switch self {
        case .linear: "Linear"
        case .log: "Log"
        case .mel: "Mel"
        case .bark: "Bark"
        }
    }

    func forward(_ f: Double) -> Double {
        switch self {
        case .linear: f
        case .log: Foundation.log2(max(f, 1))
        case .mel: 2595 * log10(1 + f / 700)
        case .bark: 26.81 * f / (1960 + f) - 0.53 // Traunmüller
        }
    }

    func inverse(_ s: Double) -> Double {
        switch self {
        case .linear: s
        case .log: pow(2, s)
        case .mel: 700 * (pow(10, s / 2595) - 1)
        case .bark: 1960 * (s + 0.53) / (26.28 - s)
        }
    }

    /// Position of `f` in 0...1 between `lo` and `hi` on this scale.
    func position(of f: Double, lo: Double, hi: Double) -> Double {
        let s0 = forward(lo), s1 = forward(hi)
        return (forward(f) - s0) / (s1 - s0)
    }
}

enum WindowFunction: String, Codable, CaseIterable, Identifiable {
    case hann, hamming, blackmanHarris, rectangular
    var id: Self { self }

    var label: String {
        switch self {
        case .hann: "Hann"
        case .hamming: "Hamming"
        case .blackmanHarris: "Blackman-Harris"
        case .rectangular: "Rect"
        }
    }
}

enum BandAggregation: String, Codable, CaseIterable, Identifiable {
    case peak, rms, mean
    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum VizMode: String, Codable, CaseIterable, Identifiable {
    case bars, mirror, radial, line, spectrogram, waveform
    var id: Self { self }

    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .bars: "chart.bar.fill"
        case .mirror: "align.vertical.center.fill"
        case .radial: "circle.dashed"
        case .line: "waveform.path.ecg"
        case .spectrogram: "square.stack.3d.down.forward.fill"
        case .waveform: "waveform"
        }
    }
}

enum Palette: String, Codable, CaseIterable, Identifiable {
    case spectrum, neon, fire, ice, aurora, mono
    var id: Self { self }
    var label: String { rawValue.capitalized }

    /// `t` = position along the frequency axis (0...1), `level` = band level (0...1), `drift` = hue offset.
    func rgb(t: Double, level: Double, drift: Double) -> SIMD3<Double> {
        let level = min(max(level, 0), 1)
        let t = min(max(t, 0), 1)
        // Ping-pong so gradient palettes can drift without a seam.
        let shifted = 1 - abs((((t + drift) * 0.5).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 2 - 1)
        switch self {
        case .spectrum:
            return Self.hsb(hue: t * 0.78 + drift, sat: 0.95 - 0.5 * pow(level, 4), bri: 0.3 + 0.7 * level)
        case .neon:
            let c = Self.gradient([[1, 0.1, 0.75], [0.55, 0.2, 1], [0.1, 0.9, 1]], shifted)
            return Self.mix(c * (0.35 + 0.65 * level), [1, 1, 1], pow(level, 6) * 0.5)
        case .fire:
            return Self.gradient([[0.08, 0, 0], [0.75, 0.05, 0], [1, 0.42, 0], [1, 0.82, 0.2], [1, 1, 0.9]],
                                 level * 0.88 + 0.12 * (1 - t))
        case .ice:
            return Self.gradient([[0, 0.02, 0.12], [0, 0.28, 0.65], [0.2, 0.72, 1], [0.92, 1, 1]], level * 0.9 + 0.1 * t)
        case .aurora:
            let c = Self.gradient([[0.1, 1, 0.5], [0.05, 0.75, 0.85], [0.45, 0.3, 1], [0.95, 0.3, 0.75]], shifted)
            return c * (0.3 + 0.7 * level)
        case .mono:
            let v = 0.25 + 0.75 * level
            return [v, v, v]
        }
    }

    static func gradient(_ stops: [SIMD3<Double>], _ x: Double) -> SIMD3<Double> {
        let x = min(max(x, 0), 1) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return mix(stops[i], stops[i + 1], x - Double(i))
    }

    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ f: Double) -> SIMD3<Double> { a + (b - a) * f }

    static func hsb(hue: Double, sat: Double, bri: Double) -> SIMD3<Double> {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = bri * sat
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = bri - c
        let rgb: SIMD3<Double> = switch Int(h) {
        case 0: [c, x, 0]
        case 1: [x, c, 0]
        case 2: [0, c, x]
        case 3: [0, x, c]
        case 4: [x, 0, c]
        default: [c, 0, x]
        }
        return rgb + m
    }
}

enum OverlayEdge: String, Codable {
    case top, bottom, left, right
}

enum OverlayPlacement: String, Codable, CaseIterable, Identifiable {
    case bottom, top, left, right, sides, topBottom, frame, notch
    var id: Self { self }

    var label: String {
        switch self {
        case .bottom: "Bottom"
        case .top: "Top"
        case .left: "Left"
        case .right: "Right"
        case .sides: "Both sides"
        case .topBottom: "Top + bottom"
        case .frame: "Frame (all edges)"
        case .notch: "Notch"
        }
    }

    var edges: [OverlayEdge] {
        switch self {
        case .bottom: [.bottom]
        case .top: [.top]
        case .left: [.left]
        case .right: [.right]
        case .sides: [.left, .right]
        case .topBottom: [.top, .bottom]
        case .frame: [.top, .bottom, .left, .right]
        case .notch: []
        }
    }
}

enum OverlayStyle: String, Codable, CaseIterable, Identifiable {
    case bars, wave, glow
    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum NotchStyle: String, Codable, CaseIterable, Identifiable {
    case aura, island, breathe, halo, underline, dots, wings
    var id: Self { self }
    var label: String { rawValue.capitalized }

    var blurb: String {
        switch self {
        case .aura: "Soft wavy gradient glowing out from behind the notch"
        case .island: "Black island grows out of the notch with bars inside"
        case .breathe: "The notch itself quietly grows and shrinks, no bars"
        case .halo: "Glowing wavy ring floating around the notch"
        case .underline: "Hairline spectrum just below the notch"
        case .dots: "Row of small dots under the notch"
        case .wings: "Small bars spread sideways from the notch along the menu bar"
        }
    }
}

enum NotchSource: String, Codable, CaseIterable, Identifiable {
    case all, bass, mid, treble
    var id: Self { self }
    var label: String { rawValue.capitalized }

    var range: ClosedRange<Double> {
        switch self {
        case .all: 0...30_000
        case .bass: 0...250
        case .mid: 250...4000
        case .treble: 4000...30_000
        }
    }
}

/// Per-display overlay override. `placement == nil` follows the global placement.
struct DisplayOverlay: Codable, Equatable {
    var enabled: Bool
    var placement: OverlayPlacement?
}

/// Live-wallpaper copy of the main visualizer, drawn between the wallpaper and the desktop icons.
struct DesktopParams: Codable, Equatable {
    var enabled = false
    var allScreens = true
    var opacity = 0.9
    var seeThrough = false
    /// Hide completely on any display that has an app window on it.
    var onlyEmptyDesktops = true
}

/// Settings for the always-on-top screen overlay. Presets leave these alone.
struct OverlayParams: Codable, Equatable {
    var enabled = false
    var placement: OverlayPlacement = .bottom
    var style: OverlayStyle = .bars
    var thickness = 90.0
    var length = 1.0
    var opacity = 0.85
    var symmetric = true
    var displays: [String: DisplayOverlay] = [:]
    var spanDisplays = false
    var skipSharedEdges = true
    var behindMenuBar = false
    var menuBarOnly = false

    // Notch
    var notchStyle: NotchStyle = .aura
    var notchSource: NotchSource = .all
    var notchSpread = 180.0
    var notchDepth = 70.0
    var notchBase = 0.4
    var notchReactivity = 0.9
    var notchSmoothing = 0.15
    var notchBars = 24
    var notchGlow = 0.5
    var notchBeat = 0.5
    var notchMono = false
    var notchWave = 0.5
    var notchSoftness = 14.0
    var notchNudgeX = 0.0

    static let notchLooks: [(name: String, apply: (inout OverlayParams) -> Void)] = [
        ("Aura", {
            $0.notchStyle = .aura; $0.notchMono = false; $0.notchSpread = 180; $0.notchDepth = 70; $0.notchBase = 0.4
            $0.notchWave = 0.5; $0.notchSoftness = 14; $0.notchReactivity = 0.9; $0.notchSmoothing = 0.15
            $0.notchGlow = 0.5; $0.notchBeat = 0.5; $0.notchSource = .all
        }),
        ("Big aura", {
            $0.notchStyle = .aura; $0.notchMono = false; $0.notchSpread = 320; $0.notchDepth = 140; $0.notchBase = 0.5
            $0.notchWave = 0.7; $0.notchSoftness = 24; $0.notchReactivity = 1.1; $0.notchSmoothing = 0.12
            $0.notchGlow = 0.8; $0.notchBeat = 0.8; $0.notchSource = .all
        }),
        ("Halo ring", {
            $0.notchStyle = .halo; $0.notchMono = false; $0.notchSpread = 140; $0.notchDepth = 50; $0.notchBase = 0.35
            $0.notchWave = 0.4; $0.notchSoftness = 10; $0.notchReactivity = 0.9; $0.notchSmoothing = 0.15
            $0.notchGlow = 0.6; $0.notchBeat = 0.5
        }),
        ("Faint aura", {
            $0.notchStyle = .aura; $0.notchMono = true; $0.notchSpread = 90; $0.notchDepth = 30; $0.notchBase = 0.3
            $0.notchWave = 0.3; $0.notchSoftness = 18; $0.notchReactivity = 0.6; $0.notchSmoothing = 0.4
            $0.notchGlow = 0.3; $0.notchBeat = 0.15
        }),
        ("Whisper halo", {
            $0.notchStyle = .halo; $0.notchMono = true; $0.notchReactivity = 0.5; $0.notchSmoothing = 0.35
            $0.notchGlow = 0.3; $0.notchBeat = 0.2; $0.notchSource = .all
        }),
        ("Hairline", {
            $0.notchStyle = .underline; $0.notchMono = false; $0.notchSpread = 60; $0.notchBars = 32
            $0.notchReactivity = 0.6; $0.notchSmoothing = 0.15; $0.notchGlow = 0.25; $0.notchBeat = 0.2
        }),
        ("Breathing notch", {
            $0.notchStyle = .breathe; $0.notchSource = .bass; $0.notchSpread = 40; $0.notchDepth = 14
            $0.notchReactivity = 0.6; $0.notchSmoothing = 0.25; $0.notchGlow = 0; $0.notchBeat = 0.3
        }),
        ("Dot row", {
            $0.notchStyle = .dots; $0.notchMono = true; $0.notchBars = 16; $0.notchSpread = 30; $0.notchDepth = 40
            $0.notchReactivity = 0.8; $0.notchSmoothing = 0.1; $0.notchGlow = 0.2; $0.notchBeat = 0.3
        }),
        ("Menu bar wings", {
            $0.notchStyle = .wings; $0.notchSpread = 140; $0.notchBars = 28; $0.notchMono = false
            $0.notchReactivity = 0.8; $0.notchSmoothing = 0.08; $0.notchGlow = 0.2; $0.notchBeat = 0.3
        }),
        ("Island (loud)", {
            $0.notchStyle = .island; $0.notchSpread = 160; $0.notchDepth = 80; $0.notchBars = 32; $0.notchMono = false
            $0.notchReactivity = 0.9; $0.notchSmoothing = 0.06; $0.notchGlow = 0.6; $0.notchBeat = 0.8
        }),
    ]

    /// Displays without saved settings: only the main display is on.
    func config(for display: DisplayInfo) -> DisplayOverlay {
        displays[display.id] ?? DisplayOverlay(enabled: display.isPrimary)
    }
}

/// Every knob in the app. Codable so it persists and so presets are plain values.
struct VizParams: Codable, Equatable {
    // Frequency analysis
    var fftSize = 8192
    var window: WindowFunction = .blackmanHarris
    var minFreq = 30.0
    var maxFreq = 16_000.0
    var bandCount = 96
    var scale: FrequencyScale = .log
    var aggregation: BandAggregation = .peak

    // Spectral shaping
    var gainDB = 0.0
    var tiltDBPerOct = 3.0
    var aWeighting = false
    var lowGainDB = 0.0
    var midGainDB = 0.0
    var highGainDB = 0.0
    var lowCrossover = 250.0
    var highCrossover = 4000.0
    var curve = 1.0

    // Fixed range (used when AGC is off)
    var floorDB = -70.0
    var ceilingDB = -12.0

    // Adaptive
    var agcEnabled = true
    var agcRangeDB = 48.0
    var agcHeadroomDB = 2.0
    var agcReleaseSec = 4.0
    var agcMaxBoostDB = 36.0
    var whitening = 0.3
    var whiteningSec = 8.0
    var floorAdapt = 0.0
    var gateDB = -90.0

    // Motion
    var attackMS = 12.0
    var releaseMS = 160.0
    var spatialSmoothing = 0.15
    var peakHoldMS = 450.0
    var peakFall = 1.2

    // Beat detection
    var beatEnabled = true
    var beatLowHz = 40.0
    var beatHighHz = 160.0
    var beatThreshold = 1.5
    var beatPulse = 0.6
    var beatDecayMS = 200.0

    // Look
    var mode: VizMode = .bars
    var palette: Palette = .spectrum
    var barGap = 0.25
    var glow = 0.5
    var hueDrift = 0.0
    var showPeaks = true
    var showLabels = true
    var showHUD = true

    var overlay = OverlayParams()
    var desktop = DesktopParams()

    static let validFFTSizes = [1024, 2048, 4096, 8192, 16384]

    static let presets: [(name: String, params: VizParams)] = [
        ("Default", VizParams()),
        ("Bass Focus", with {
            $0.minFreq = 20; $0.maxFreq = 300; $0.bandCount = 48; $0.fftSize = 16384; $0.scale = .log
            $0.tiltDBPerOct = 0; $0.beatLowHz = 35; $0.beatHighHz = 120; $0.palette = .fire; $0.mode = .mirror
            $0.glow = 0.8; $0.beatPulse = 0.9
        }),
        ("Vocals & Mids", with {
            $0.minFreq = 150; $0.maxFreq = 5000; $0.bandCount = 128; $0.scale = .mel; $0.tiltDBPerOct = 1.5
            $0.midGainDB = 3; $0.lowCrossover = 300; $0.highCrossover = 3500; $0.palette = .aurora; $0.mode = .line
            $0.beatLowHz = 150; $0.beatHighHz = 2000
        }),
        ("Hi-Res Analyzer", with {
            $0.fftSize = 16384; $0.bandCount = 256; $0.minFreq = 20; $0.maxFreq = 20_000; $0.agcEnabled = false
            $0.whitening = 0; $0.tiltDBPerOct = 0; $0.aggregation = .peak; $0.floorDB = -90; $0.ceilingDB = 0
            $0.attackMS = 0; $0.releaseMS = 80; $0.spatialSmoothing = 0; $0.barGap = 0.1; $0.glow = 0
            $0.palette = .mono; $0.beatEnabled = false
        }),
        ("Punchy EDM", with {
            $0.fftSize = 4096; $0.bandCount = 64; $0.attackMS = 0; $0.releaseMS = 110; $0.whitening = 0.6
            $0.whiteningSec = 4; $0.agcReleaseSec = 2; $0.agcRangeDB = 36; $0.curve = 1.4; $0.beatPulse = 1
            $0.beatThreshold = 1.2; $0.palette = .neon; $0.mode = .radial; $0.glow = 0.9; $0.hueDrift = 0.5
        }),
        ("Chill / Ambient", with {
            $0.attackMS = 120; $0.releaseMS = 900; $0.spatialSmoothing = 0.5; $0.whitening = 0.5
            $0.whiteningSec = 20; $0.agcReleaseSec = 12; $0.palette = .ice; $0.mode = .line; $0.glow = 0.7
            $0.beatPulse = 0.2; $0.showPeaks = false
        }),
        ("Transient Hunter", with {
            $0.floorAdapt = 0.8; $0.whitening = 0.5; $0.attackMS = 0; $0.releaseMS = 90; $0.curve = 1.6
            $0.bandCount = 128; $0.fftSize = 2048; $0.mode = .spectrogram; $0.palette = .fire
        }),
        ("Scope", with {
            $0.mode = .waveform; $0.palette = .neon; $0.glow = 0.8
        }),
    ]

    private static func with(_ edit: (inout VizParams) -> Void) -> VizParams {
        var p = VizParams()
        edit(&p)
        return p
    }
}
