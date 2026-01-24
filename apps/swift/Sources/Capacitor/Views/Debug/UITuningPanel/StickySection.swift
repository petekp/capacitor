import SwiftUI

#if DEBUG

struct StickySection<Content: View>: View {
    let title: String
    let onReset: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @State private var isResetHovered = false

    init(title: String, onReset: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.onReset = onReset
        self.content = content
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        } header: {
            stickyHeader
        }
    }

    private var stickyHeader: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.5)

            Spacer()

            if let onReset = onReset {
                Button(action: onReset) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Reset")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(isResetHovered ? 0.8 : 0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(isResetHovered ? 0.1 : 0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isResetHovered = hovering
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                VibrancyView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    isEmphasized: true,
                    forceDarkAppearance: true
                )
                Color.black.opacity(0.5)
            }
        )
    }
}

struct TuningRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: String = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Text(String(format: format, value))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 45, alignment: .trailing)
            }

            CustomSlider(value: $value, range: range)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let trackHeight: CGFloat = 2
    private let thumbSize: CGFloat = 8
    private let hitboxHeight: CGFloat = 14

    var body: some View {
        SliderTrackView(value: $value, range: range, trackHeight: trackHeight, thumbSize: thumbSize, hitboxHeight: hitboxHeight)
            .frame(height: hitboxHeight)
    }
}

private struct SliderTrackView: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let trackHeight: CGFloat
    let thumbSize: CGFloat
    let hitboxHeight: CGFloat

    func makeNSView(context: Context) -> SliderNSView {
        let view = SliderNSView()
        view.onValueChanged = { newValue in
            let clampedValue = min(max(newValue, 0), 1)
            value = range.lowerBound + clampedValue * (range.upperBound - range.lowerBound)
        }
        view.trackHeight = trackHeight
        view.thumbSize = thumbSize
        return view
    }

    func updateNSView(_ nsView: SliderNSView, context: Context) {
        nsView.normalizedValue = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        nsView.needsDisplay = true
    }
}

private class SliderNSView: NSView {
    var normalizedValue: Double = 0
    var onValueChanged: ((Double) -> Void)?
    var trackHeight: CGFloat = 2
    var thumbSize: CGFloat = 10
    private var isDragging = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let width = bounds.width
        let centerY = bounds.height / 2
        let thumbX = normalizedValue * (width - thumbSize)

        // Track background
        let trackRect = NSRect(x: 0, y: centerY - trackHeight / 2, width: width, height: trackHeight)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        NSColor.white.withAlphaComponent(0.15).setFill()
        trackPath.fill()

        // Track fill
        let fillWidth = max(0, thumbX + thumbSize / 2)
        let fillRect = NSRect(x: 0, y: centerY - trackHeight / 2, width: fillWidth, height: trackHeight)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        NSColor.white.withAlphaComponent(0.9).setFill()
        fillPath.fill()

        // Thumb
        let thumbRect = NSRect(x: thumbX, y: centerY - thumbSize / 2, width: thumbSize, height: thumbSize)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: thumbRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        window?.disableCursorRects()
        updateValue(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging {
            updateValue(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        window?.enableCursorRects()
    }

    private func updateValue(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let newValue = location.x / bounds.width
        onValueChanged?(newValue)
    }
}

struct TuningPickerRow<T: Hashable>: View {
    let label: String
    @Binding var selection: T
    let options: [(String, T)]

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            Picker("", selection: $selection) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .labelsHidden()
        }
    }
}

struct BlendModeOption: Identifiable {
    let id = UUID()
    let mode: BlendMode
    let icon: String
    let tooltip: String
}

struct TuningBlendModeRow: View {
    let label: String
    @Binding var selection: BlendMode
    let options: [BlendModeOption]

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            HStack(spacing: 2) {
                ForEach(options) { option in
                    BlendModeButton(
                        option: option,
                        isSelected: selection == option.mode,
                        onSelect: { selection = option.mode }
                    )
                }
            }
        }
    }
}

private struct BlendModeButton: View {
    let option: BlendModeOption
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: option.icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.5))
                .frame(width: 24, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? Color.white.opacity(0.2) : (isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.04)))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(option.tooltip)
    }
}

extension BlendModeOption {
    static let shadowModes: [BlendModeOption] = [
        BlendModeOption(mode: .normal, icon: "circle", tooltip: "Normal"),
        BlendModeOption(mode: .multiply, icon: "multiply", tooltip: "Multiply"),
        BlendModeOption(mode: .overlay, icon: "square.on.square", tooltip: "Overlay"),
        BlendModeOption(mode: .softLight, icon: "sun.min", tooltip: "Soft Light"),
        BlendModeOption(mode: .hardLight, icon: "sun.max", tooltip: "Hard Light"),
        BlendModeOption(mode: .colorBurn, icon: "flame", tooltip: "Color Burn"),
    ]

    static let highlightModes: [BlendModeOption] = [
        BlendModeOption(mode: .normal, icon: "circle", tooltip: "Normal"),
        BlendModeOption(mode: .plusLighter, icon: "plus", tooltip: "Plus Lighter"),
        BlendModeOption(mode: .screen, icon: "rectangle.on.rectangle", tooltip: "Screen"),
        BlendModeOption(mode: .overlay, icon: "square.on.square", tooltip: "Overlay"),
        BlendModeOption(mode: .softLight, icon: "sun.min", tooltip: "Soft Light"),
        BlendModeOption(mode: .colorDodge, icon: "bolt", tooltip: "Color Dodge"),
    ]

    static let compositingModes: [BlendModeOption] = [
        BlendModeOption(mode: .normal, icon: "circle", tooltip: "Normal"),
        BlendModeOption(mode: .plusLighter, icon: "plus", tooltip: "Plus Lighter"),
        BlendModeOption(mode: .screen, icon: "rectangle.on.rectangle", tooltip: "Screen"),
        BlendModeOption(mode: .overlay, icon: "square.on.square", tooltip: "Overlay"),
        BlendModeOption(mode: .multiply, icon: "multiply", tooltip: "Multiply"),
        BlendModeOption(mode: .luminosity, icon: "sun.max", tooltip: "Luminosity"),
    ]
}

struct TuningToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.65)
        }
    }
}

struct TuningColorRow: View {
    let label: String
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
                    .shadow(color: color.opacity(0.5), radius: 3)
            }

            TuningRow(label: "Hue", value: $hue, range: 0...1)
            TuningRow(label: "Saturation", value: $saturation, range: 0...1)
            TuningRow(label: "Brightness", value: $brightness, range: 0...1)
        }
    }
}

struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 6)
    }
}

#endif
