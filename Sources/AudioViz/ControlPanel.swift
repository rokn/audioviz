import SwiftUI

struct ControlPanel: View {
    @Environment(AppModel.self) private var model
    private let d = VizParams()
    private let grid = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                section("View") {
                    Picker("Mode", selection: $model.params.mode) {
                        ForEach(VizMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                        .resettable($model.params.mode, to: d.mode, "Mode")
                    Picker("Palette", selection: $model.params.palette) {
                        ForEach(Palette.allCases) { Text($0.label).tag($0) }
                    }
                        .resettable($model.params.palette, to: d.palette, "Palette")
                    LazyVGrid(columns: grid, spacing: 10) {
                        Knob(label: "Gap", value: $model.params.barGap, range: 0...0.9, defaultValue: d.barGap,
                             format: Fmt.pct, help: "Space between bars")
                        Knob(label: "Glow", value: $model.params.glow, range: 0...1, defaultValue: d.glow,
                             format: Fmt.pct, help: "Bloom intensity")
                        Knob(label: "Hue drift", value: $model.params.hueDrift, range: 0...10, defaultValue: d.hueDrift,
                             format: { String(format: "%.1f/min", $0) }, help: "Palette rotation speed (cycles per minute)")
                    }
                    HStack {
                        Toggle("Peaks", isOn: $model.params.showPeaks)
                            .resettable($model.params.showPeaks, to: d.showPeaks, "Peaks")
                        Toggle("Labels", isOn: $model.params.showLabels)
                            .resettable($model.params.showLabels, to: d.showLabels, "Labels")
                        Toggle("HUD", isOn: $model.params.showHUD)
                            .resettable($model.params.showHUD, to: d.showHUD, "HUD")
                    }
                    .toggleStyle(.checkbox)
                }

                section("Desktop") {
                    Toggle("Show visualizer on the desktop", isOn: $model.params.desktop.enabled)
                        .help("Live wallpaper: the current visualizer drawn behind all windows and desktop icons")
                    HStack {
                        Toggle("All displays", isOn: $model.params.desktop.allScreens)
                            .resettable($model.params.desktop.allScreens, to: d.desktop.allScreens, "All displays")
                        Toggle("See-through", isOn: $model.params.desktop.seeThrough)
                            .resettable($model.params.desktop.seeThrough, to: d.desktop.seeThrough, "See-through")
                            .help("Draw over your wallpaper instead of on black")
                    }
                    .toggleStyle(.checkbox)
                    Toggle("Only on displays with no windows", isOn: $model.params.desktop.onlyEmptyDesktops)
                        .resettable($model.params.desktop.onlyEmptyDesktops, to: d.desktop.onlyEmptyDesktops, "Only empty displays")
                        .help("Fade out on any display that has an app window on it; fade back in when it's clear")
                        .toggleStyle(.checkbox)
                    LazyVGrid(columns: grid, spacing: 10) {
                        Knob(label: "Opacity", value: $model.params.desktop.opacity, range: 0.1...1, defaultValue: d.desktop.opacity,
                             format: Fmt.pct, help: "Desktop visualizer opacity")
                    }
                }

                section("Screen overlay") {
                    Toggle("Show on screen", isOn: $model.params.overlay.enabled)
                        .help("Always-on-top, click-through visualizer on your screen edges or around the notch")
                    Picker("Placement", selection: $model.params.overlay.placement) {
                        ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
                    }
                    .resettable($model.params.overlay.placement, to: d.overlay.placement, "Placement")
                    Picker("Style", selection: $model.params.overlay.style) {
                        ForEach(OverlayStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .resettable($model.params.overlay.style, to: d.overlay.style, "Style")
                    LazyVGrid(columns: grid, spacing: 10) {
                        Knob(label: "Thickness", value: $model.params.overlay.thickness, range: 16...400, logarithmic: true,
                             defaultValue: d.overlay.thickness, format: { "\(Int($0)) pt" },
                             help: "How far the overlay reaches in from the edge (notch: how far the island drops)")
                        Knob(label: "Length", value: $model.params.overlay.length, range: 0.1...1, defaultValue: d.overlay.length,
                             format: Fmt.pct, help: "How much of the edge is covered, centred (notch: how wide the island can spread)")
                        Knob(label: "Opacity", value: $model.params.overlay.opacity, range: 0.1...1, defaultValue: d.overlay.opacity,
                             format: Fmt.pct, help: "Overlay opacity")
                    }
                    if usesTopOrNotch {
                        Toggle("Behind the menu bar", isOn: $model.params.overlay.behindMenuBar)
                            .resettable($model.params.overlay.behindMenuBar, to: d.overlay.behindMenuBar, "Behind the menu bar")
                            .help("Top edge and notch draw underneath the menu bar: menu titles and status icons stay on top")
                            .toggleStyle(.checkbox)
                        if model.params.overlay.behindMenuBar {
                            Toggle("Top edge: fill only the menu bar", isOn: $model.params.overlay.menuBarOnly)
                                .resettable($model.params.overlay.menuBarOnly, to: d.overlay.menuBarOnly, "Fill only the menu bar")
                                .help("Size the top strip to exactly the menu bar's height, ignoring Thickness")
                                .toggleStyle(.checkbox)
                                .padding(.leading, 18)
                        }
                    }
                    Toggle("Bass in middle", isOn: $model.params.overlay.symmetric)
                        .resettable($model.params.overlay.symmetric, to: d.overlay.symmetric, "Bass in middle")
                        .help("Mirror the spectrum so low frequencies sit at the centre of each edge")
                        .toggleStyle(.checkbox)
                    displayList
                    if usesNotch { notchControls }
                }

                section("Frequencies") {
                    LazyVGrid(columns: grid, spacing: 10) {
                        Knob(label: "Min", value: $model.params.minFreq, range: 10...5000, logarithmic: true,
                             defaultValue: d.minFreq, format: Fmt.hz, help: "Lowest frequency shown (Hz)")
                        Knob(label: "Max", value: $model.params.maxFreq, range: 100...24_000, logarithmic: true,
                             defaultValue: d.maxFreq, format: Fmt.hz, help: "Highest frequency shown (Hz)")
                        Knob(label: "Bands", value: intBinding($model.params.bandCount), range: 8...256, step: 1,
                             defaultValue: Double(d.bandCount), format: Fmt.int, help: "Number of bars / bands")
                        Knob(label: "Tilt", value: $model.params.tiltDBPerOct, range: -3...9, defaultValue: d.tiltDBPerOct,
                             format: { String(format: "%+.1f/oct", $0) },
                             help: "dB per octave pivoting at 1 kHz. ~3 makes typical music look flat")
                    }
                    Picker("Scale", selection: $model.params.scale) {
                        ForEach(FrequencyScale.allCases) { Text($0.label).tag($0) }
                    }
                        .resettable($model.params.scale, to: d.scale, "Scale")
                    .pickerStyle(.segmented)
                    Picker("FFT", selection: $model.params.fftSize) {
                        ForEach(VizParams.validFFTSizes, id: \.self) { Text($0 >= 1024 ? "\($0 / 1024)k" : "\($0)").tag($0) }
                    }
                        .resettable($model.params.fftSize, to: d.fftSize, "FFT")
                    .pickerStyle(.segmented)
                    .help("Bigger FFT = finer frequency detail (better bass), but slower time response")
                    Picker("Window", selection: $model.params.window) {
                        ForEach(WindowFunction.allCases) { Text($0.label).tag($0) }
                    }
                        .resettable($model.params.window, to: d.window, "Window")
                    Picker("Band value", selection: $model.params.aggregation) {
                        ForEach(BandAggregation.allCases) { Text($0.label).tag($0) }
                    }
                        .resettable($model.params.aggregation, to: d.aggregation, "Band value")
                    .pickerStyle(.segmented)
                    .help("How FFT bins inside a band are combined")
                }

                section("EQ / Focus") {
                    LazyVGrid(columns: grid, spacing: 10) {
                        Knob(label: "Low", value: $model.params.lowGainDB, range: -24...24, defaultValue: 0,
                             format: Fmt.db, help: "Gain below the low crossover")
                        Knob(label: "Mid", value: $model.params.midGainDB, range: -24...24, defaultValue: 0,
                             format: Fmt.db, help: "Gain between crossovers")
                        Knob(label: "High", value: $model.params.highGainDB, range: -24...24, defaultValue: 0,
                             format: Fmt.db, help: "Gain above the high crossover")
                        Knob(label: "Gain", value: $model.params.gainDB, range: -24...24, defaultValue: 0,
                             format: Fmt.db, help: "Overall gain")
                        Knob(label: "Low X", value: $model.params.lowCrossover, range: 40...2000, logarithmic: true,
                             defaultValue: d.lowCrossover, format: Fmt.hz, help: "Low/mid crossover (Hz)")
                        Knob(label: "High X", value: $model.params.highCrossover, range: 500...16_000, logarithmic: true,
                             defaultValue: d.highCrossover, format: Fmt.hz, help: "Mid/high crossover (Hz)")
                        Knob(label: "Curve", value: $model.params.curve, range: 0.3...3, logarithmic: true,
                             defaultValue: 1, format: Fmt.x, help: "Response curve: <1 lifts quiet detail, >1 makes peaks punchier")
                    }
                    Toggle("A-weighting (perceived loudness)", isOn: $model.params.aWeighting)
                        .resettable($model.params.aWeighting, to: d.aWeighting, "A-weighting")
                }

                section("Adaptive") {
                    Toggle("Auto gain (AGC)", isOn: $model.params.agcEnabled)
                        .resettable($model.params.agcEnabled, to: d.agcEnabled, "Auto gain (AGC)")
                        .help("Continuously re-centres the dB window on how loud the music currently is")
                    LazyVGrid(columns: grid, spacing: 10) {
                        if model.params.agcEnabled {
                            Knob(label: "Range", value: $model.params.agcRangeDB, range: 12...96, defaultValue: d.agcRangeDB,
                                 format: Fmt.dbAbs, help: "Dynamic range shown below the tracked peak")
                            Knob(label: "Headroom", value: $model.params.agcHeadroomDB, range: -12...12, defaultValue: d.agcHeadroomDB,
                                 format: Fmt.db, help: "Space above the tracked peak. Negative = bars clip at the top more often")
                            Knob(label: "AGC rel", value: $model.params.agcReleaseSec, range: 0.3...30, logarithmic: true,
                                 defaultValue: d.agcReleaseSec, format: Fmt.sec, help: "How fast gain recovers after a loud passage")
                            Knob(label: "Max boost", value: $model.params.agcMaxBoostDB, range: 0...72, defaultValue: d.agcMaxBoostDB,
                                 format: Fmt.dbAbs, help: "Limit on how far quiet audio is amplified (relative to Ceiling)")
                        }
                        Knob(label: "Floor", value: $model.params.floorDB, range: -120 ... -20, defaultValue: d.floorDB,
                             format: Fmt.dbAbs, help: "Bottom of the dB window when AGC is off")
                        Knob(label: "Ceiling", value: $model.params.ceilingDB, range: -60...6, defaultValue: d.ceilingDB,
                             format: Fmt.dbAbs, help: "Top of the dB window when AGC is off (and reference for Max boost)")
                        Knob(label: "Whiten", value: $model.params.whitening, range: 0...1, defaultValue: d.whitening,
                             format: Fmt.pct, help: "Per-band auto-leveling: lifts bands that are usually quiet so every band gets used")
                        Knob(label: "Whiten t", value: $model.params.whiteningSec, range: 0.5...60, logarithmic: true,
                             defaultValue: d.whiteningSec, format: Fmt.sec, help: "Memory of the per-band leveling")
                        Knob(label: "Floor adapt", value: $model.params.floorAdapt, range: 0...1, defaultValue: d.floorAdapt,
                             format: Fmt.pct, help: "Raises each band's floor to its own sustained level: hides drones, emphasizes changes")
                        Knob(label: "Gate", value: $model.params.gateDB, range: -120 ... -20, defaultValue: d.gateDB,
                             format: Fmt.dbAbs, help: "Treat everything as silence when the loudest band is below this")
                    }
                }

                section("Motion") {
                    LazyVGrid(columns: grid, spacing: 10) {
                        Knob(label: "Attack", value: $model.params.attackMS, range: 0...500, defaultValue: d.attackMS,
                             format: Fmt.ms, help: "Rise smoothing")
                        Knob(label: "Release", value: $model.params.releaseMS, range: 0...3000, defaultValue: d.releaseMS,
                             format: Fmt.ms, help: "Fall smoothing")
                        Knob(label: "Smooth", value: $model.params.spatialSmoothing, range: 0...0.66, defaultValue: d.spatialSmoothing,
                             format: Fmt.pct, help: "Blend neighbouring bands")
                        Knob(label: "Peak hold", value: $model.params.peakHoldMS, range: 0...3000, defaultValue: d.peakHoldMS,
                             format: Fmt.ms, help: "How long peak markers stay put")
                        Knob(label: "Peak fall", value: $model.params.peakFall, range: 0.1...5, logarithmic: true,
                             defaultValue: d.peakFall, format: Fmt.x, help: "Peak marker fall speed (heights per second)")
                    }
                }

                section("Beat") {
                    Toggle("Beat detection", isOn: $model.params.beatEnabled)
                        .resettable($model.params.beatEnabled, to: d.beatEnabled, "Beat detection")
                    if model.params.beatEnabled {
                        LazyVGrid(columns: grid, spacing: 10) {
                            Knob(label: "Low", value: $model.params.beatLowHz, range: 20...8000, logarithmic: true,
                                 defaultValue: d.beatLowHz, format: Fmt.hz, help: "Lower edge of the band listened to for beats")
                            Knob(label: "High", value: $model.params.beatHighHz, range: 40...16_000, logarithmic: true,
                                 defaultValue: d.beatHighHz, format: Fmt.hz, help: "Upper edge of the beat band. Kick ≈ 40–160, snare ≈ 150–4k, hats ≈ 6k+")
                            Knob(label: "Threshold", value: $model.params.beatThreshold, range: 0.3...4, defaultValue: d.beatThreshold,
                                 format: { String(format: "%.1fσ", $0) }, help: "Adaptive threshold above the recent average. Lower = more beats")
                            Knob(label: "Pulse", value: $model.params.beatPulse, range: 0...1.5, defaultValue: d.beatPulse,
                                 format: Fmt.pct, help: "How strongly visuals react to beats")
                            Knob(label: "Decay", value: $model.params.beatDecayMS, range: 30...1000, logarithmic: true,
                                 defaultValue: d.beatDecayMS, format: Fmt.ms, help: "Beat pulse decay")
                        }
                    }
                }
            }
            .padding(14)
        }
        .scrollIndicators(.never)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AudioViz").font(.headline)
                Spacer()
                Menu("Presets") {
                    ForEach(VizParams.presets, id: \.name) { preset in
                        Button(preset.name) { model.apply(preset: preset.params) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    model.apply(preset: VizParams())
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isAtDefaults)
                .help("Reset all knobs to defaults, except the overlay (right-click any control to reset just that one)")
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(model.status == .running ? "Stop" : "Start") {
                    model.status == .running ? model.stop() : model.start()
                }
                .controlSize(.small)
            }
        }
    }

    private var usesTopOrNotch: Bool {
        let o = model.params.overlay
        let placements = [o.placement] + model.displays.compactMap { o.config(for: $0).placement }
        return placements.contains { $0 == .notch || $0.edges.contains(.top) }
    }

    private var usesNotch: Bool {
        let o = model.params.overlay
        return o.placement == .notch || model.displays.contains { o.config(for: $0).placement == .notch }
    }

    private var notchControls: some View {
        @Bindable var model = model
        let o = d.overlay
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notch").font(.system(size: 11, weight: .semibold))
                Spacer()
                Menu("Looks") {
                    ForEach(OverlayParams.notchLooks, id: \.name) { look in
                        Button(look.name) { look.apply(&model.params.overlay) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Picker("Style", selection: $model.params.overlay.notchStyle) {
                ForEach(NotchStyle.allCases) { Text($0.label).tag($0) }
            }
            .resettable($model.params.overlay.notchStyle, to: o.notchStyle, "Notch style")
            Text(model.params.overlay.notchStyle.blurb).font(.caption).foregroundStyle(.secondary)
            Picker("React to", selection: $model.params.overlay.notchSource) {
                ForEach(NotchSource.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .resettable($model.params.overlay.notchSource, to: o.notchSource, "React to")
            .help("Which part of the spectrum drives the notch (and which bands its bars show)")
            LazyVGrid(columns: grid, spacing: 10) {
                Knob(label: "H spread", value: $model.params.overlay.notchSpread, range: 0...600, defaultValue: o.notchSpread,
                     format: { "\(Int($0)) pt" }, help: "Horizontal spread: how far it can extend sideways from the notch")
                Knob(label: "V spread", value: $model.params.overlay.notchDepth, range: 4...300, logarithmic: true,
                     defaultValue: o.notchDepth, format: { "\(Int($0)) pt" }, help: "Vertical spread: how far it can drop below the notch")
                Knob(label: "React", value: $model.params.overlay.notchReactivity, range: 0...1.5, defaultValue: o.notchReactivity,
                     format: Fmt.pct, help: "How strongly size follows the music. Low = subtle")
                Knob(label: "Calm", value: $model.params.overlay.notchSmoothing, range: 0...1.5, defaultValue: o.notchSmoothing,
                     format: Fmt.sec, help: "Extra smoothing of the notch's movement")
                Knob(label: "Bars", value: Binding(get: { Double(model.params.overlay.notchBars) },
                                                   set: { model.params.overlay.notchBars = Int($0.rounded()) }),
                     range: 4...96, step: 1, defaultValue: Double(o.notchBars), format: Fmt.int,
                     help: "Number of bars / segments / dots")
                Knob(label: "Glow", value: $model.params.overlay.notchGlow, range: 0...1, defaultValue: o.notchGlow,
                     format: Fmt.pct, help: "Soft light around the notch")
                Knob(label: "Idle size", value: $model.params.overlay.notchBase, range: 0...1, defaultValue: o.notchBase,
                     format: Fmt.pct, help: "Aura/Halo: how big it stays between hits (share of the spread that's always shown)")
                Knob(label: "Wave", value: $model.params.overlay.notchWave, range: 0...1, defaultValue: o.notchWave,
                     format: Fmt.pct, help: "Aura: how much the outline ripples")
                Knob(label: "Softness", value: $model.params.overlay.notchSoftness, range: 0...60, defaultValue: o.notchSoftness,
                     format: { "\(Int($0)) pt" }, help: "Aura: blur of the glow")
                Knob(label: "Nudge X", value: $model.params.overlay.notchNudgeX, range: -20...20, step: 0.5,
                     defaultValue: o.notchNudgeX, format: { String(format: "%+.1f", $0) },
                     help: "Fine horizontal alignment with the hardware notch")
                Knob(label: "Beat", value: $model.params.overlay.notchBeat, range: 0...1.5, defaultValue: o.notchBeat,
                     format: Fmt.pct, help: "How much beats bump the notch")
            }
            Toggle("Monochrome", isOn: $model.params.overlay.notchMono)
                .resettable($model.params.overlay.notchMono, to: o.notchMono, "Monochrome")
                .help("White instead of the palette. Blends in with the menu bar")
                .toggleStyle(.checkbox)
        }
    }

    private var displayList: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            Text("Displays").font(.system(size: 11, weight: .semibold))
            ForEach(model.displays) { display in
                let config = model.displayConfig(display)
                HStack(spacing: 6) {
                    Toggle(isOn: config.enabled) {
                        HStack(spacing: 4) {
                            Image(systemName: display.hasNotch ? "laptopcomputer" : "display")
                            Text(display.id).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                    Spacer(minLength: 4)
                    Picker("", selection: config.placement) {
                        Text("Same as above").tag(OverlayPlacement?.none)
                        Divider()
                        ForEach(OverlayPlacement.allCases) { Text($0.label).tag(OverlayPlacement?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(!config.wrappedValue.enabled)
                }
                .font(.system(size: 11))
                .help("\(display.id) — \(Int(display.size.width))×\(Int(display.size.height)) pt\(display.isPrimary ? " · main display" : "")")
            }
            if model.displays.count > 1 {
                Toggle("Span edges across displays", isOn: $model.params.overlay.spanDisplays)
                    .resettable($model.params.overlay.spanDisplays, to: d.overlay.spanDisplays, "Span edges")
                    .help("Same-side edges on different displays show one continuous spectrum")
                Toggle("Skip edges where displays touch", isOn: $model.params.overlay.skipSharedEdges)
                    .resettable($model.params.overlay.skipSharedEdges, to: d.overlay.skipSharedEdges, "Skip shared edges")
                    .help("Don't draw on the inner edges between side-by-side or stacked monitors")
            }
        }
        .toggleStyle(.checkbox)
    }

    private var statusText: String {
        switch model.status {
        case .idle: "Stopped"
        case .running: "Listening · \(model.deviceName)"
        case let .failed(message): message
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .gray
        case .running: .green
        case .failed: .red
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func intBinding(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }
}
