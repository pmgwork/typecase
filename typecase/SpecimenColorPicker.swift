import AppKit
import SwiftUI

/// Shared by the toolbar and Settings. Presentation stays attached to its button.
struct SpecimenColorPicker<Label: View>: View {
    @Binding var color: Color?
    let fallback: Color
    let title: String
    @ViewBuilder var label: () -> Label
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: { label() }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .help(title)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                SpecimenColorPopover(color: $color, fallback: fallback, title: title)
            }
    }
}

private struct SpecimenColorPopover: View {
    @Binding var color: Color?
    let fallback: Color
    let title: String
    @State private var hue = 0.0
    @State private var saturation = 0.0
    @State private var brightness = 1.0
    @State private var lastWrittenColor: Color?
    @State private var activeRegion: Region?
    @FocusState private var pickerFocused: Bool

    /// The hue ring and the saturation/brightness field inside it.
    private enum Region { case ring, field }

    private let outer: CGFloat = 248
    private let ringWidth: CGFloat = 34
    private let gap: CGFloat = 6
    private let ringHandle: CGFloat = 42
    private let fieldHandle: CGFloat = 26
    private let fieldCornerRadius: CGFloat = 12

    /// The field is a rounded square as large as the ring's inner circle
    /// allows: its rounded corners stay clear of the ring at every angle.
    private var fieldSide: CGFloat {
        let limit = outer / 2 - ringWidth - gap
        return 2 * ((limit - fieldCornerRadius) / 2.0.squareRoot() + fieldCornerRadius)
    }

    private var fieldOrigin: CGFloat { (outer - fieldSide) / 2 }

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            picker
            Button("Use System Color") {
                color = nil
                synchronize()
            }
            .controlSize(.small)
            .disabled(color == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: outer + 40)
        .onAppear(perform: synchronize)
        .onChange(of: color) { _, newColor in
            // Preserve hue/saturation at black, and hue at the white center.
            if newColor != lastWrittenColor { synchronize() }
        }
        .onChange(of: fallback) { _, _ in
            if color == nil { synchronize() }
        }
    }

    // MARK: - Picker

    private var picker: some View {
        ZStack {
            hueRing
            saturationBrightnessField
        }
        .frame(width: outer, height: outer)
        .contentShape(.circle)
        .gesture(selectionGesture)
        .focusable()
        .focused($pickerFocused)
        // ← → turn the hue ring; with Shift they move across the field's
        // saturation axis. ↑ ↓ move along its brightness axis.
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in
            press.modifiers.contains(.shift) ? adjustSaturation(-0.02) : adjustHue(-0.01)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in
            press.modifiers.contains(.shift) ? adjustSaturation(0.02) : adjustHue(0.01)
            return .handled
        }
        .onKeyPress(.upArrow) { brightness = min(1, brightness + 0.02); publish(); return .handled }
        .onKeyPress(.downArrow) { brightness = max(0, brightness - 0.02); publish(); return .handled }
        .accessibilityRepresentation {
            VStack {
                Slider(value: componentBinding($hue), in: 0...1) { Text("Hue") }
                Slider(value: componentBinding($saturation), in: 0...1) { Text("Saturation") }
                Slider(value: componentBinding($brightness), in: 0...1) { Text("Brightness") }
            }
        }
        .help("Choose a color. Arrow keys adjust hue and brightness; Shift-arrow keys adjust saturation.")
    }

    /// The hue wheel as a ring: the angular gradient starts at 3 o'clock and
    /// runs clockwise, matching the angle-to-hue conversion of the drag.
    private var hueRing: some View {
        let radius = (outer - ringWidth) / 2
        let angle = hue * 2 * .pi
        return Circle()
            .strokeBorder(
                AngularGradient(
                    colors: (0...12).map { Color(hue: 1 - Double($0) / 12, saturation: 1, brightness: 1) },
                    center: .center
                ),
                lineWidth: ringWidth
            )
            .frame(width: outer, height: outer)
            .overlay {
                Circle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .frame(width: ringHandle, height: ringHandle)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: cos(angle) * radius, y: -sin(angle) * radius)
                    .allowsHitTesting(false)
            }
    }

    /// The saturation/brightness field: white at the leading edge, the full hue
    /// at the trailing edge, black at the bottom.
    private var saturationBrightnessField: some View {
        let offset = handleOffset
        return ZStack {
            Color(hue: hue, saturation: 1, brightness: 1)
            LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: fieldSide, height: fieldSide)
        .clipShape(RoundedRectangle(cornerRadius: fieldCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .overlay {
            Circle()
                .strokeBorder(.white, lineWidth: 2.5)
                .frame(width: fieldHandle, height: fieldHandle)
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                .offset(x: offset.width, y: offset.height)
                .allowsHitTesting(false)
        }
    }

    /// The region is decided where the drag starts, so a drag that crosses the
    /// ring keeps adjusting the control it began on.
    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let region = activeRegion ?? region(at: value.startLocation)
                activeRegion = region
                switch region {
                case .ring: updateHue(at: value.location)
                case .field: updateSaturationBrightness(at: value.location)
                }
            }
            .onEnded { _ in activeRegion = nil }
    }

    private func region(at point: CGPoint) -> Region {
        isInsideField(point) ? .field : .ring
    }

    /// The rounded-rectangle containment test for the field.
    private func isInsideField(_ point: CGPoint) -> Bool {
        let x = point.x - fieldOrigin
        let y = point.y - fieldOrigin
        guard x >= 0, y >= 0, x <= fieldSide, y <= fieldSide else { return false }
        let radius = fieldCornerRadius
        let inset = fieldSide - radius
        let clampedX = min(max(x, radius), inset)
        let clampedY = min(max(y, radius), inset)
        return hypot(x - clampedX, y - clampedY) <= radius
    }

    private func updateHue(at point: CGPoint) {
        let center = CGPoint(x: outer / 2, y: outer / 2)
        let x = point.x - center.x
        let y = center.y - point.y
        guard hypot(x, y) > 0.5 else { return }
        hue = (atan2(y, x) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
        publish()
    }

    private func updateSaturationBrightness(at point: CGPoint) {
        saturation = min(max((point.x - fieldOrigin) / fieldSide, 0), 1)
        brightness = min(max(1 - (point.y - fieldOrigin) / fieldSide, 0), 1)
        publish()
    }

    /// The handle's offset from the field's center. Values can sit in the
    /// field's square corners, which the rounded shape cuts away, so the drawn
    /// position is pulled back onto the visible edge.
    private var handleOffset: CGSize {
        let point = clampedFieldPoint(
            CGPoint(x: saturation * fieldSide, y: (1 - brightness) * fieldSide)
        )
        return CGSize(width: point.x - fieldSide / 2, height: point.y - fieldSide / 2)
    }

    private func clampedFieldPoint(_ point: CGPoint) -> CGPoint {
        let radius = fieldCornerRadius
        let inset = fieldSide - radius
        let outsideX = point.x < radius || point.x > inset
        let outsideY = point.y < radius || point.y > inset
        guard outsideX, outsideY else {
            return CGPoint(x: min(max(point.x, radius), inset), y: min(max(point.y, radius), inset))
        }
        let corner = CGPoint(x: point.x < radius ? radius : inset, y: point.y < radius ? radius : inset)
        let dx = point.x - corner.x
        let dy = point.y - corner.y
        let length = hypot(dx, dy)
        guard length > radius else { return point }
        return CGPoint(x: corner.x + dx / length * radius, y: corner.y + dy / length * radius)
    }

    private func componentBinding(_ state: Binding<Double>) -> Binding<Double> {
        Binding(get: { state.wrappedValue }, set: { state.wrappedValue = $0; publish() })
    }

    private func adjustHue(_ delta: Double) {
        hue = (hue + delta + 1).truncatingRemainder(dividingBy: 1)
        publish()
    }

    private func adjustSaturation(_ delta: Double) {
        saturation = min(max(saturation + delta, 0), 1)
        publish()
    }

    private func publish() {
        let next = Color(hue: hue, saturation: saturation, brightness: brightness)
        lastWrittenColor = next
        color = next
    }

    private func synchronize() {
        let rgb = NSColor(color ?? fallback).usingColorSpace(.sRGB) ?? .black
        hue = rgb.hueComponent
        saturation = rgb.saturationComponent
        brightness = rgb.brightnessComponent
        lastWrittenColor = color
    }
}
