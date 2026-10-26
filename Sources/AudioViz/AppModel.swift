import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
final class AppModel {
    enum Status: Equatable {
        case idle, running, failed(String)
    }

    var params: VizParams {
        didSet {
            save()
            if params.overlay != oldValue.overlay { overlay?.sync() }
            if params.desktop != oldValue.desktop {
                desktop?.sync()
                updateActivationPolicy()
            }
        }
    }
    var showControls = true
    /// Connected displays, kept current by the overlay controller.
    var displays: [DisplayInfo] = []
    private(set) var status: Status = .idle

    @ObservationIgnored let capture: SystemAudioCapture
    @ObservationIgnored let analyzer: Analyzer
    @ObservationIgnored private(set) var overlay: OverlayController?
    @ObservationIgnored private(set) var desktop: DesktopController?
    @ObservationIgnored private var lastTick = 0.0
    @ObservationIgnored private static let defaultsKey = "params.v1"

    init() {
        let ring = SampleRing()
        capture = SystemAudioCapture(ring: ring)
        analyzer = Analyzer(ring: ring)
        params = UserDefaults.standard.data(forKey: Self.defaultsKey).flatMap(Self.decodeMerged) ?? VizParams()
        capture.observeDefaultOutputChanges { [weak self] in
            guard let self, self.status == .running else { return }
            self.start()
        }
    }

    var deviceName: String { capture.deviceName }

    /// True when everything except the overlay settings is at its default.
    var isAtDefaults: Bool {
        var d = VizParams()
        d.overlay = params.overlay
        return params == d
    }

    func displayConfig(_ display: DisplayInfo) -> Binding<DisplayOverlay> {
        Binding(get: { self.params.overlay.config(for: display) },
                set: { self.params.overlay.displays[display.id] = $0 })
    }

    /// Called once the app is up (AppKit windows can't be created during App init).
    func launch() {
        if overlay == nil { overlay = OverlayController(model: self) }
        overlay?.sync()
        if desktop == nil { desktop = DesktopController(model: self) }
        desktop?.sync()
        if status != .running { start() }
        // Give SwiftUI a moment to restore windows before deciding whether we need a Dock icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.updateActivationPolicy() }
    }

    /// Whether something keeps the app useful with no window open.
    var runsWithoutWindow: Bool { params.overlay.enabled || params.desktop.enabled }

    /// With no AudioViz window open, run as a menu bar app (no Dock icon, not in ⌘-Tab) so the desktop/overlay
    /// visualizers have no other side effects. Any open window brings the Dock icon back.
    func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
        let policy: NSApplication.ActivationPolicy = hasWindow || !runsWithoutWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Advances the analyzer once per frame, however many views (main window, overlay panels) are drawing.
    func tick(_ t: Double) {
        guard abs(t - lastTick) > 0.004 else { return }
        lastTick = t
        analyzer.update(params, sampleRate: capture.sampleRate, time: t)
    }

    func start() {
        do {
            try capture.start()
            status = .running
        } catch {
            capture.stop()
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        capture.stop()
        status = .idle
    }

    /// Applies a preset but keeps the current overlay setup.
    func apply(preset: VizParams) {
        var p = preset
        p.overlay = params.overlay
        params = p
    }

    /// Decodes saved settings on top of the defaults, so settings saved by older versions still load.
    private static func decodeMerged(_ data: Data) -> VizParams? {
        func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
            base.merging(over) { old, new in
                if let o = old as? [String: Any], let n = new as? [String: Any] { return merge(o, n) }
                return new
            }
        }
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(VizParams())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: merge(defaults, migrate(saved)))
        else { return nil }
        return try? JSONDecoder().decode(VizParams.self, from: merged)
    }

    /// Notch settings saved before the adaptive notch (no `notchBase`) were tuned for a much smaller glow: drop them.
    private static func migrate(_ saved: [String: Any]) -> [String: Any] {
        guard var overlay = saved["overlay"] as? [String: Any], overlay["notchBase"] == nil else { return saved }
        overlay = overlay.filter { !$0.key.hasPrefix("notch") }
        var result = saved
        result["overlay"] = overlay
        return result
    }

    private func save() {
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
