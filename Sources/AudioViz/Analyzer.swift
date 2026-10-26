import Accelerate
import CoreGraphics

private struct BandLayout: Equatable {
    var fftSize: Int
    var sampleRate: Double
    var minFreq: Double
    var maxFreq: Double
    var count: Int
    var scale: FrequencyScale
}

/// How a band reads the FFT: a contiguous run of bins, or (for bands narrower than a bin) interpolation at its center.
private struct BandMap {
    var lo: Int
    var count: Int
    var frac: Float
    var interpolated: Bool { count == 0 }
}

/// Turns raw samples into display-ready band levels. Runs on the main thread, once per rendered frame.
final class Analyzer {
    static let maxFFT = 16384
    static let waveformLength = 2048
    let spectrogramWidth = 600

    private let ring: SampleRing
    private let fftSetup: FFTSetup
    private let input = UnsafeMutablePointer<Float>.allocate(capacity: maxFFT)
    private let windowed = UnsafeMutablePointer<Float>.allocate(capacity: maxFFT)
    private let re = UnsafeMutablePointer<Float>.allocate(capacity: maxFFT / 2)
    private let im = UnsafeMutablePointer<Float>.allocate(capacity: maxFFT / 2)
    private let mag = UnsafeMutablePointer<Float>.allocate(capacity: maxFFT / 2)
    private let binDB = UnsafeMutablePointer<Float>.allocate(capacity: maxFFT / 2)
    private let prevBinDB = UnsafeMutablePointer<Float>.allocate(capacity: maxFFT / 2)

    private var window = [Float]()
    private var windowKind: WindowFunction?
    private var windowGain: Float = 1

    private var layout: BandLayout?
    private var bandMaps = [BandMap]()
    private var weights = [Float]()
    private var rawDB = [Float]()
    private var target = [Float]()
    private var scratch = [Float]()
    private var bandPeakDB = [Float]()
    private var noiseFloorDB = [Float]()
    private var peakTimers = [Float]()

    // Read by the renderer
    private(set) var levels = [Float]()
    private(set) var peaks = [Float]()
    private(set) var bandCenters = [Double]()
    private(set) var effectiveMinFreq = 20.0
    private(set) var effectiveMaxFreq = 20_000.0
    private(set) var fftSize = 0
    private(set) var sampleRate = 48_000.0
    private(set) var runningPeakDB: Float = -40
    private(set) var ceilingDB: Float = -12
    private(set) var floorDB: Float = -70
    private(set) var beat: Float = 0
    private(set) var bpm: Double?
    private(set) var silentFor: Double = 0
    private(set) var waveform = [Float](repeating: 0, count: waveformLength)
    private(set) var waveTrigger = 0
    private(set) var waveEnvelope: Float = 0.05

    private var fluxHistory = [(time: Double, flux: Float)]()
    private var lastBeatTime = -10.0
    private var beatIntervals = [Double]()
    private var prevBinsValid = false

    private var specPixels = [UInt32]()
    private(set) var spectrogramHeight = 0
    private var lut = [UInt32](repeating: 0, count: 256)

    private var lastTime: Double?
    private var lastTotal: UInt64 = 0
    private var staleFor = 0.0

    init(ring: SampleRing) {
        self.ring = ring
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(Self.maxFFT))), FFTRadix(kFFTRadix2))!
        input.initialize(repeating: 0, count: Self.maxFFT)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        [input, windowed, re, im, mag, binDB, prevBinDB].forEach { $0.deallocate() }
    }

    // MARK: - Frame update

    func update(_ p: VizParams, sampleRate sr: Double, time t: Double) {
        let dt = Float(min(max(t - (lastTime ?? t - 1.0 / 60), 0.001), 0.1))
        lastTime = t
        let n = VizParams.validFFTSizes.contains(p.fftSize) ? p.fftSize : 8192
        let half = n / 2
        sampleRate = sr
        if n != fftSize { prevBinsValid = false }
        fftSize = n

        prepareWindow(p.window, n)
        prepareLayout(BandLayout(fftSize: n, sampleRate: sr, minFreq: p.minFreq, maxFreq: p.maxFreq,
                                 count: max(4, p.bandCount), scale: p.scale))
        prepareWeights(p)

        // Pull audio; if the capture stops delivering, fade to silence instead of freezing.
        let total = ring.readLatest(into: input, count: n)
        staleFor = total == lastTotal ? staleFor + Double(dt) : 0
        lastTotal = total
        if staleFor > 0.25 { vDSP_vclr(input, 1, vDSP_Length(n)) }
        updateWaveform(dt)

        var inputPeak: Float = 0
        vDSP_maxmgv(input, 1, &inputPeak, vDSP_Length(n))
        silentFor = inputPeak < 1e-5 ? silentFor + Double(dt) : 0

        // FFT -> linear amplitude per bin, calibrated so a full-scale sine reads ~0 dBFS.
        vDSP_vmul(input, 1, window, 1, windowed, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: re, imagp: im)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
        im[0] = 0 // zrip packs Nyquist here
        vDSP_zvmags(&split, 1, mag, 1, vDSP_Length(half))
        var count32 = Int32(half)
        vvsqrtf(mag, mag, &count32)
        var scale = 1 / (Float(n) * windowGain)
        vDSP_vsmul(mag, 1, &scale, mag, 1, vDSP_Length(half))
        mag[0] = 0 // drop DC

        computeBands(p, half: half)
        let silent = adapt(p, dt: dt)
        detectBeat(p, dt: dt, time: t, half: half, silent: silent)
        smoothAndHold(p, dt: dt)
        pushSpectrogramColumn(p, time: t)
    }

    private func computeBands(_ p: VizParams, half: Int) {
        for b in 0..<bandMaps.count {
            let m = bandMaps[b]
            var a: Float = 0
            if m.interpolated {
                a = mag[m.lo] * (1 - m.frac) + mag[min(m.lo + 1, half - 1)] * m.frac
            } else {
                let len = vDSP_Length(m.count)
                switch p.aggregation {
                case .peak: vDSP_maxv(mag + m.lo, 1, &a, len)
                case .rms: vDSP_rmsqv(mag + m.lo, 1, &a, len)
                case .mean: vDSP_meanv(mag + m.lo, 1, &a, len)
                }
            }
            rawDB[b] = 20 * log10(a + 1e-9) + weights[b]
        }
    }

    /// AGC, per-band whitening and adaptive floor. Writes normalized 0...1 values into `target`.
    /// Returns whether the frame is below the noise gate.
    private func adapt(_ p: VizParams, dt: Float) -> Bool {
        var frameMax: Float = -200
        vDSP_maxv(rawDB, 1, &frameMax, vDSP_Length(rawDB.count))

        let peakTau: Float = frameMax > runningPeakDB ? 0.05 : Float(p.agcReleaseSec)
        runningPeakDB += (frameMax - runningPeakDB) * coef(dt, peakTau)
        runningPeakDB = max(runningPeakDB, -200)

        if p.agcEnabled {
            ceilingDB = max(runningPeakDB + Float(p.agcHeadroomDB), Float(p.ceilingDB - p.agcMaxBoostDB))
            floorDB = ceilingDB - Float(p.agcRangeDB)
        } else {
            ceilingDB = Float(p.ceilingDB)
            floorDB = min(Float(p.floorDB), ceilingDB - 1)
        }
        let reference = ceilingDB - (p.agcEnabled ? Float(p.agcHeadroomDB) : 0)
        let maxLift = (ceilingDB - floorDB) * 0.6
        let silent = frameMax < Float(p.gateDB)

        let peakAttack = coef(dt, 0.1), peakRelease = coef(dt, Float(p.whiteningSec))
        let nfFall = coef(dt, 0.4), nfRise = coef(dt, 6)
        let whitening = Float(p.whitening), floorAdapt = Float(p.floorAdapt), curve = Float(p.curve)

        for b in 0..<rawDB.count {
            let raw = rawDB[b]

            // Whitening: lift each band toward the global peak based on its own recent peak.
            let bp = bandPeakDB[b]
            bandPeakDB[b] = max(bp + (raw - bp) * (raw > bp ? peakAttack : peakRelease), floorDB)
            let lift = whitening * min(max(0, reference - bandPeakDB[b]), maxLift)

            // Adaptive floor: slow-rising minimum tracker suppresses steady drones/noise per band.
            let nf = noiseFloorDB[b]
            noiseFloorDB[b] = nf + (raw - nf) * (raw < nf ? nfFall : nfRise)
            var floor = floorDB
            if floorAdapt > 0 {
                floor += floorAdapt * max(0, noiseFloorDB[b] + lift + 3 - floorDB)
                floor = min(floor, ceilingDB - 6)
            }

            var v = (raw + lift - floor) / (ceilingDB - floor)
            v = min(max(v, 0), 1)
            if curve != 1 { v = pow(v, curve) }
            target[b] = silent ? 0 : v
        }
        return silent
    }

    private func detectBeat(_ p: VizParams, dt: Float, time t: Double, half: Int, silent: Bool) {
        beat *= exp(-dt / max(Float(p.beatDecayMS) / 1000, 0.01))
        guard p.beatEnabled else { return }

        // Per-bin dB clamped to the current (adaptive) floor so quiet noise doesn't create flux.
        var eps: Float = 1e-9
        vDSP_vsadd(mag, 1, &eps, binDB, 1, vDSP_Length(half))
        var one: Float = 1
        vDSP_vdbcon(binDB, 1, &one, binDB, 1, vDSP_Length(half), 1)
        var lo = floorDB, hi: Float = 20
        vDSP_vclip(binDB, 1, &lo, &hi, binDB, 1, vDSP_Length(half))

        let binHz = sampleRate / Double(fftSize)
        let first = min(max(1, Int(p.beatLowHz / binHz)), half - 1)
        let last = min(max(first, Int(p.beatHighHz / binHz)), half - 1)
        var flux: Float = 0
        if prevBinsValid {
            for k in first...last {
                let d = binDB[k] - prevBinDB[k]
                if d > 0 { flux += d }
            }
            flux /= Float(last - first + 1)
        }
        prevBinDB.update(from: binDB, count: half)
        prevBinsValid = true

        fluxHistory.append((t, flux))
        fluxHistory.removeAll { $0.time < t - 1.5 }
        let values = fluxHistory.map(\.flux)
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        let threshold = mean + Float(p.beatThreshold) * variance.squareRoot()

        if !silent, flux > threshold, flux > 0.3, t - lastBeatTime > 0.18, values.count > 10 {
            let interval = t - lastBeatTime
            if (0.27...1.5).contains(interval) {
                beatIntervals.append(interval)
                if beatIntervals.count > 16 { beatIntervals.removeFirst() }
            }
            lastBeatTime = t
            beat = 1
            if beatIntervals.count >= 4 {
                var bpm = 60 / beatIntervals.sorted()[beatIntervals.count / 2]
                while bpm < 80 { bpm *= 2 }
                while bpm > 180 { bpm /= 2 }
                self.bpm = bpm
            }
        }
        if t - lastBeatTime > 4 {
            bpm = nil
            beatIntervals.removeAll()
        }
    }

    private func smoothAndHold(_ p: VizParams, dt: Float) {
        let count = target.count
        let s = Float(p.spatialSmoothing)
        if s > 0 {
            scratch = target
            for b in 0..<count {
                let l = scratch[max(b - 1, 0)], r = scratch[min(b + 1, count - 1)]
                target[b] = scratch[b] * (1 - s) + (l + r) * s / 2
            }
        }

        let up = coef(dt, Float(p.attackMS) / 1000)
        let down = coef(dt, Float(p.releaseMS) / 1000)
        let hold = Float(p.peakHoldMS) / 1000
        let fall = Float(p.peakFall) * dt
        for b in 0..<count {
            let tv = target[b], l = levels[b]
            levels[b] = l + (tv - l) * (tv > l ? up : down)
            if levels[b] >= peaks[b] {
                peaks[b] = levels[b]
                peakTimers[b] = hold
            } else if peakTimers[b] > 0 {
                peakTimers[b] -= dt
            } else {
                peaks[b] = max(levels[b], peaks[b] - fall)
            }
        }
    }

    private func updateWaveform(_ dt: Float) {
        waveform.withUnsafeMutableBufferPointer { w in
            _ = ring.readLatest(into: w.baseAddress!, count: Self.waveformLength)
        }
        // Trigger on a rising zero crossing so the scope stays still.
        let span = Self.waveformLength / 2
        waveTrigger = 0
        for i in 1..<span where waveform[i - 1] <= 0 && waveform[i] > 0 {
            waveTrigger = i
            break
        }
        var peak: Float = 0
        vDSP_maxmgv(waveform, 1, &peak, vDSP_Length(Self.waveformLength))
        waveEnvelope = max(peak, waveEnvelope * exp(-dt / 1.5), 0.002)
    }

    // MARK: - Spectrogram

    private func pushSpectrogramColumn(_ p: VizParams, time t: Double) {
        let h = levels.count
        let w = spectrogramWidth
        if spectrogramHeight != h || specPixels.count != w * h {
            spectrogramHeight = h
            specPixels = [UInt32](repeating: 0xFF00_0000, count: w * h)
        }
        let drift = p.hueDrift * t / 60
        for i in 0..<256 {
            let x = Double(i) / 255
            let c = p.palette.rgb(t: x, level: x, drift: drift)
            lut[i] = UInt32(c.x * 255) | UInt32(c.y * 255) << 8 | UInt32(c.z * 255) << 16 | 0xFF00_0000
        }
        specPixels.withUnsafeMutableBufferPointer { px in
            let base = px.baseAddress!
            memmove(base, base + 1, (px.count - 1) * MemoryLayout<UInt32>.size)
            for row in 0..<h {
                let v = levels[h - 1 - row]
                base[row * w + w - 1] = lut[Int(min(max(v, 0), 1) * 255)]
            }
        }
    }

    func spectrogramImage() -> CGImage? {
        guard spectrogramHeight > 0 else { return nil }
        let data = specPixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: spectrogramWidth, height: spectrogramHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: spectrogramWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Setup

    private func prepareWindow(_ kind: WindowFunction, _ n: Int) {
        guard kind != windowKind || window.count != n else { return }
        windowKind = kind
        window = (0..<n).map { i -> Float in
            let x: Double = 2 * Double.pi * Double(i) / Double(n)
            let w: Double
            switch kind {
            case .hann: w = 0.5 - 0.5 * cos(x)
            case .hamming: w = 0.54 - 0.46 * cos(x)
            case .blackmanHarris:
                let a: Double = 0.35875 - 0.48829 * cos(x)
                w = a + 0.14128 * cos(2 * x) - 0.01168 * cos(3 * x)
            case .rectangular: w = 1
            }
            return Float(w)
        }
        windowGain = window.reduce(0, +) / Float(n)
    }

    private func prepareLayout(_ l: BandLayout) {
        guard l != layout else { return }
        layout = l
        let half = l.fftSize / 2
        let binHz = l.sampleRate / Double(l.fftSize)
        let nyquist = l.sampleRate / 2
        let lo = min(max(l.minFreq, binHz), nyquist * 0.5)
        let hi = min(max(l.maxFreq, lo * 1.5), nyquist)
        effectiveMinFreq = lo
        effectiveMaxFreq = hi

        let s0 = l.scale.forward(lo), s1 = l.scale.forward(hi)
        let c = l.count
        let edges = (0...c).map { l.scale.inverse(s0 + (s1 - s0) * Double($0) / Double(c)) }
        bandCenters = (0..<c).map { l.scale.inverse(s0 + (s1 - s0) * (Double($0) + 0.5) / Double(c)) }
        bandMaps = (0..<c).map { b in
            let first = max(1, Int((edges[b] / binHz).rounded(.up)))
            let last = min(half - 1, Int((edges[b + 1] / binHz).rounded(.down)))
            if last >= first { return BandMap(lo: first, count: last - first + 1, frac: 0) }
            let x = bandCenters[b] / binHz
            let i = min(max(Int(x), 0), half - 2)
            return BandMap(lo: i, count: 0, frac: Float(min(max(x - Double(i), 0), 1)))
        }

        if levels.count != c {
            levels = Array(repeating: 0, count: c)
            peaks = levels
            peakTimers = levels
            target = levels
            rawDB = Array(repeating: -120, count: c)
            bandPeakDB = Array(repeating: -60, count: c)
            noiseFloorDB = Array(repeating: -100, count: c)
            weights = levels
        }
    }

    private func prepareWeights(_ p: VizParams) {
        let lowX = log2(p.lowCrossover), highX = log2(max(p.highCrossover, p.lowCrossover * 1.1))
        for (b, f) in bandCenters.enumerated() {
            let x = log2(f)
            var w = p.gainDB + p.tiltDBPerOct * (x - log2(1000))
            if p.aWeighting { w += Self.aWeight(f) }
            let lowW = 1 - smoothstep(lowX - 0.5, lowX + 0.5, x)
            let highW = smoothstep(highX - 0.5, highX + 0.5, x)
            let midW = max(0, 1 - lowW - highW)
            w += lowW * p.lowGainDB + midW * p.midGainDB + highW * p.highGainDB
            weights[b] = Float(w)
        }
    }

    private static func aWeight(_ f: Double) -> Double {
        let f2 = f * f
        let ra = (12194.0 * 12194.0 * f2 * f2)
            / ((f2 + 20.6 * 20.6) * ((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)).squareRoot() * (f2 + 12194.0 * 12194.0))
        return 20 * log10(max(ra, 1e-12)) + 2.0
    }

    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// One-pole smoothing coefficient for time constant `tau` seconds.
    private func coef(_ dt: Float, _ tau: Float) -> Float {
        tau <= 0.0005 ? 1 : 1 - exp(-dt / tau)
    }
}
