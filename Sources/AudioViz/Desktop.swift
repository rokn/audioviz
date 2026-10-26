import AppKit
import SwiftUI

/// Whether a desktop panel should render: paused while windows fully cover it or it's hidden for having windows.
@Observable
final class DesktopVisibility {
    var occluded = false
    var hiddenForWindows = false
    var visible: Bool { !occluded && !hiddenForWindows }
}

/// Draws the main visualizer as a live wallpaper: above the wallpaper, below desktop icons, never takes clicks.
final class DesktopController {
    private weak var model: AppModel?
    private var panels: [(screen: NSRect, panel: NSPanel, visibility: DesktopVisibility, observer: Any)] = []
    private var screenObserver: Any?
    private var workspaceObservers: [Any] = []
    private var pollTimer: Timer?

    /// One level above the wallpaper; desktop icons sit higher, so they stay visible and clickable.
    private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    init(model: AppModel) {
        self.model = model
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
        // React right away to Space and app switches; the timer catches windows opening, closing and moving.
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                              NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                              NSWorkspace.didTerminateApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.updateWindowPresence() }
        }
    }

    func sync() {
        guard let model else { return }
        let d = model.params.desktop
        let frames = d.enabled ? (d.allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))).map(\.frame) : []
        updatePolling()
        guard frames != panels.map(\.screen) else {
            updateWindowPresence()
            return
        }

        for p in panels {
            NotificationCenter.default.removeObserver(p.observer)
            p.panel.close()
        }
        panels = frames.map { frame in
            let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = Self.level
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false

            let visibility = DesktopVisibility()
            let host = NSHostingView(rootView: DesktopView(model: model, visibility: visibility).ignoresSafeArea())
            host.sizingOptions = []
            panel.contentView = host
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()

            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
            ) { [weak self, weak panel] _ in
                guard let panel else { return }
                visibility.occluded = !panel.occlusionState.contains(.visible)
                self?.reportShowing()
            }
            return (frame, panel, visibility, observer)
        }
        updateWindowPresence()
    }

    private func updatePolling() {
        let wanted = model?.params.desktop.enabled == true && model?.params.desktop.onlyEmptyDesktops == true
        if wanted, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.updateWindowPresence() }
        } else if !wanted {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    /// Fades each display's panel out while that display has any app window on it (current Space only).
    private func updateWindowPresence() {
        guard let model, !panels.isEmpty else {
            reportShowing()
            return
        }
        let occupied = model.params.desktop.onlyEmptyDesktops ? Self.displaysWithWindows(panels.map(\.screen)) : []
        for (i, p) in panels.enumerated() {
            let hide = occupied.contains(i)
            guard hide != p.visibility.hiddenForWindows else { continue }
            p.visibility.hiddenForWindows = hide
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                p.panel.animator().alphaValue = hide ? 0 : 1
            }
        }
        reportShowing()
    }

    /// The overlay steps aside on every display where the desktop visualizer is showing.
    private func reportShowing() {
        model?.overlay?.suppress(on: panels.filter { $0.visibility.visible }.map(\.screen))
    }

    /// Indices of `screens` that hold at least one normal app window. Each window counts for the display holding most of it.
    private static func displaysWithWindows(_ screens: [NSRect]) -> Set<Int> {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        // Window bounds use a top-left origin; flip screens into the same space.
        let flipped = screens.map { CGRect(x: $0.minX, y: primary.frame.maxY - $0.maxY, width: $0.width, height: $0.height) }
        var result = Set<Int>()
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict),
                  b.width > 60, b.height > 60 else { continue }
            let areas = flipped.map { s -> CGFloat in
                let i = s.intersection(b)
                return i.isNull ? 0 : i.width * i.height
            }
            if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
                result.insert(best)
            }
        }
        return result
    }
}

private struct DesktopView: View {
    let model: AppModel
    let visibility: DesktopVisibility

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !visibility.visible)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                model.tick(t)
                let d = model.params.desktop
                ctx.opacity = d.opacity
                Renderer.draw(&ctx, size: size, a: model.analyzer, p: model.params, time: t,
                              chrome: false, background: !d.seeThrough)
            }
        }
    }
}
