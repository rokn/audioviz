import SwiftUI

@main
struct AudioVizApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup("AudioViz", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 720, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandMenu("Visualizer") {
                Button(model.showControls ? "Hide Controls" : "Show Controls") { model.showControls.toggle() }
                    .keyboardShortcut("k")
                Toggle("Screen Overlay", isOn: Bindable(model).params.overlay.enabled)
                    .keyboardShortcut("o")
                Toggle("Desktop Visualizer", isOn: Bindable(model).params.desktop.enabled)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(VizMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button(mode.label) { model.params.mode = mode }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Next Palette") {
                    let all = Palette.allCases
                    model.params.palette = all[(all.firstIndex(of: model.params.palette)! + 1) % all.count]
                }
                .keyboardShortcut("p")
                Button("Restart Capture") { model.start() }
                    .keyboardShortcut("r")
                Button("Reset All Knobs") { model.apply(preset: VizParams()) }
            }
        }

        MenuBarExtra("AudioViz", systemImage: "waveform") {
            MenuBarContent()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here so capture and the overlay start at launch even when no window is restored.
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
    }

    /// Keep running in the menu bar while the overlay or desktop visualizer is showing.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.runsWithoutWindow
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Toggle("Desktop Visualizer", isOn: $model.params.desktop.enabled)
        Toggle("Screen Overlay", isOn: $model.params.overlay.enabled)
        Picker("Placement", selection: $model.params.overlay.placement) {
            ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Behind the Menu Bar", isOn: $model.params.overlay.behindMenuBar)
        Menu("Displays") {
            ForEach(model.displays) { display in
                Toggle(display.id, isOn: model.displayConfig(display).enabled)
            }
        }
        Picker("Notch Style", selection: $model.params.overlay.notchStyle) {
            ForEach(NotchStyle.allCases) { Text($0.label).tag($0) }
        }
        Picker("Style", selection: $model.params.overlay.style) {
            ForEach(OverlayStyle.allCases) { Text($0.label).tag($0) }
        }
        Picker("Palette", selection: $model.params.palette) {
            ForEach(Palette.allCases) { Text($0.label).tag($0) }
        }
        Menu("Presets") {
            ForEach(VizParams.presets, id: \.name) { preset in
                Button(preset.name) { model.apply(preset: preset.params) }
            }
        }
        Divider()
        Button("Open AudioViz Window") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit AudioViz") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VisualizerView()
                .overlay(alignment: .topTrailing) {
                    Button { withAnimation(.snappy) { model.showControls.toggle() } } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 10)
                    .padding(.trailing, 14)
                    .help("Toggle controls (⌘K)")
                }
            if model.showControls {
                ControlPanel()
                    .frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { model.updateActivationPolicy() }
        .onDisappear {
            // The window is still listed as visible during onDisappear; check once it's gone.
            DispatchQueue.main.async { model.updateActivationPolicy() }
        }
    }
}

struct VisualizerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                model.tick(t)
                Renderer.draw(&ctx, size: size, a: model.analyzer, p: model.params, time: t)
            }
        }
    }
}
