import AppKit
import SwiftUI

/// A rotary knob. Drag up/right to increase, hold ⌥ for fine control, double-click to reset.
struct Knob: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var logarithmic = false
    var step: Double? = nil
    let defaultValue: Double
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    var help: String = ""

    @State private var dragOrigin: Double?
    @State private var hovering = false

    private var normalized: Double {
        let v = min(max(value, range.lowerBound), range.upperBound)
        if logarithmic { return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound) }
        return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func setNormalized(_ x: Double) {
        let x = min(max(x, 0), 1)
        var v = logarithmic
            ? range.lowerBound * pow(range.upperBound / range.lowerBound, x)
            : range.lowerBound + x * (range.upperBound - range.lowerBound)
        if let step { v = (v / step).rounded() * step }
        value = min(max(v, range.lowerBound), range.upperBound)
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(hovering || dragOrigin != nil ? 0.1 : 0.06))
                    .padding(5)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * normalized)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: 9)
                    .offset(y: -10)
                    .rotationEffect(.degrees(-135 + 270 * normalized))
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if dragOrigin == nil { dragOrigin = normalized }
                        let sensitivity = NSEvent.modifierFlags.contains(.option) ? 1000.0 : 180.0
                        setNormalized(dragOrigin! + (g.translation.width - g.translation.height) / sensitivity)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .onTapGesture(count: 2) { value = defaultValue }
            .onHover { hovering = $0 }

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(format(value))
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset \(label) to \(format(defaultValue))") { value = defaultValue }
                .disabled(value == defaultValue)
        }
        .help(help.isEmpty ? label : "\(label): \(help)\nDrag to change · ⌥ fine · double-click or right-click to reset")
    }
}

extension View {
    /// Right-click menu that resets a non-knob control (picker, toggle) to its default.
    func resettable<T: Equatable>(_ binding: Binding<T>, to defaultValue: T, _ label: String) -> some View {
        contextMenu {
            Button("Reset \(label)") { binding.wrappedValue = defaultValue }
                .disabled(binding.wrappedValue == defaultValue)
        }
    }
}

enum Fmt {
    static func hz(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v.rounded()))" }
    static func db(_ v: Double) -> String { String(format: "%+.0f dB", v) }
    static func dbAbs(_ v: Double) -> String { String(format: "%.0f dB", v) }
    static func ms(_ v: Double) -> String { "\(Int(v.rounded())) ms" }
    static func sec(_ v: Double) -> String { String(format: "%.1f s", v) }
    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func int(_ v: Double) -> String { "\(Int(v.rounded()))" }
    static func x(_ v: Double) -> String { String(format: "%.2f×", v) }
}
