import SwiftUI
import Combine

#if DEBUG

private struct GlassConfigKey: EnvironmentKey {
    static let defaultValue = GlassConfig.shared
}

extension EnvironmentValues {
    var glassConfig: GlassConfig {
        get { self[GlassConfigKey.self] }
        set { self[GlassConfigKey.self] = newValue }
    }
}

struct TunableColor {
    var hue: Double
    var saturation: Double
    var brightness: Double

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    static let ready = TunableColor(hue: 145/360, saturation: 0.75, brightness: 0.70)
    static let working = TunableColor(hue: 45/360, saturation: 0.65, brightness: 0.75)
    static let waiting = TunableColor(hue: 85/360, saturation: 0.70, brightness: 0.80)
    static let compacting = TunableColor(hue: 55/360, saturation: 0.55, brightness: 0.70)
    static let idle = TunableColor(hue: 0, saturation: 0, brightness: 0.5)
}

enum PreviewState: String, CaseIterable {
    case none = "None"
    case ready = "Ready"
    case working = "Working"
    case waiting = "Waiting"
    case compacting = "Compacting"
    case idle = "Idle"
}

class GlassConfig: ObservableObject {
    static let shared = GlassConfig()
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var refreshCounter: Int = 0

    init() {
        $useEmphasizedMaterial
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshCounter += 1
            }
            .store(in: &cancellables)

        $materialType
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshCounter += 1
            }
            .store(in: &cancellables)
    }

    static let materialNames = ["HUD Window", "Popover", "Menu", "Sidebar", "Full Screen UI"]

    var cardConfigHash: Int {
        var hasher = Hasher()
        hasher.combine(cardTintOpacity)
        hasher.combine(cardCornerRadius)
        hasher.combine(cardBorderOpacity)
        hasher.combine(cardHighlightOpacity)
        hasher.combine(cardHoverBorderOpacity)
        hasher.combine(cardHoverHighlightOpacity)
        hasher.combine(statusReadyHue)
        hasher.combine(statusWorkingHue)
        return hasher.finalize()
    }

    // Panel background
    @Published var panelTintOpacity: Double = 0.33
    @Published var panelCornerRadius: Double = 22
    @Published var panelBorderOpacity: Double = 0.36
    @Published var panelHighlightOpacity: Double = 0.07
    @Published var panelTopHighlightOpacity: Double = 0.14
    @Published var panelShadowOpacity: Double = 0.00
    @Published var panelShadowRadius: Double = 0
    @Published var panelShadowY: Double = 0

    // Card background
    @Published var cardTintOpacity: Double = 0.58
    @Published var cardCornerRadius: Double = 13
    @Published var cardBorderOpacity: Double = 0.28
    @Published var cardHighlightOpacity: Double = 0.14
    @Published var cardHoverBorderOpacity: Double = 0.37
    @Published var cardHoverHighlightOpacity: Double = 0.16

    // Material settings
    @Published var useEmphasizedMaterial: Bool = true
    @Published var materialType: Int = 0  // 0=hudWindow, 1=popover, 2=menu, 3=sidebar, 4=fullScreenUI

    // Status Colors - Ready (green)
    @Published var statusReadyHue: Double = 0.329
    @Published var statusReadySaturation: Double = 1.00
    @Published var statusReadyBrightness: Double = 1.00

    // Status Colors - Working (yellow/orange)
    @Published var statusWorkingHue: Double = 0.103
    @Published var statusWorkingSaturation: Double = 1.00
    @Published var statusWorkingBrightness: Double = 1.00

    // Status Colors - Waiting (coral/salmon)
    @Published var statusWaitingHue: Double = 0.026
    @Published var statusWaitingSaturation: Double = 0.58
    @Published var statusWaitingBrightness: Double = 1.00

    // Status Colors - Compacting (purple/lavender)
    @Published var statusCompactingHue: Double = 0.670
    @Published var statusCompactingSaturation: Double = 0.50
    @Published var statusCompactingBrightness: Double = 1.00

    // Status Colors - Idle (gray)
    @Published var statusIdleOpacity: Double = 0.40

    // Ready ripple effect (continuous)
    @Published var rippleSpeed: Double = 4.9
    @Published var rippleCount: Int = 4
    @Published var rippleMaxOpacity: Double = 1.00
    @Published var rippleLineWidth: Double = 30.0
    @Published var rippleBlurAmount: Double = 41.5
    @Published var rippleOriginX: Double = 0.89
    @Published var rippleOriginY: Double = 0.00
    @Published var rippleFadeInZone: Double = 0.10
    @Published var rippleFadeOutPower: Double = 4.0

    // Ready border glow effect
    @Published var borderGlowInnerWidth: Double = 0.49
    @Published var borderGlowOuterWidth: Double = 2.88
    @Published var borderGlowInnerBlur: Double = 0.5
    @Published var borderGlowOuterBlur: Double = 1.5
    @Published var borderGlowBaseOpacity: Double = 0.30
    @Published var borderGlowPulseIntensity: Double = 0.50
    @Published var borderGlowRotationMultiplier: Double = 0.50

    // Breathing dot
    @Published var breathingDotSize: Double = 12
    @Published var breathingDotShadowRadius: Double = 0
    @Published var breathingGlowSize: Double = 8
    @Published var breathingGlowBlur: Double = 5
    @Published var breathingSpeed: Double = 3.00
    @Published var breathingMinScale: Double = 0.52
    @Published var breathingMinOpacity: Double = 0.7
    @Published var breathingGlowMinScale: Double = 0.80
    @Published var breathingGlowMaxScale: Double = 1.46
    @Published var breathingGlowMinOpacity: Double = 0.25
    @Published var breathingGlowMaxOpacity: Double = 0.5
    @Published var breathingPhaseOffset: Double = 0.0  // 0-1, offset from ripple phase when synced

    // Status text settings
    @Published var statusTextSize: Double = 12
    @Published var statusTextWeight: Int = 5  // 3=light, 4=regular, 5=medium, 6=semibold, 7=bold
    @Published var statusTextSpacing: Double = 4
    @Published var statusIdleTextOpacity: Double = 0.55

    var fontWeight: Font.Weight {
        switch statusTextWeight {
        case 3: return .light
        case 4: return .regular
        case 5: return .medium
        case 6: return .semibold
        case 7: return .bold
        default: return .medium
        }
    }

    // State Preview
    @Published var previewState: PreviewState = .none

    // Computed colors
    var statusReadyColor: Color {
        Color(hue: statusReadyHue, saturation: statusReadySaturation, brightness: statusReadyBrightness)
    }
    var statusWorkingColor: Color {
        Color(hue: statusWorkingHue, saturation: statusWorkingSaturation, brightness: statusWorkingBrightness)
    }
    var statusWaitingColor: Color {
        Color(hue: statusWaitingHue, saturation: statusWaitingSaturation, brightness: statusWaitingBrightness)
    }
    var statusCompactingColor: Color {
        Color(hue: statusCompactingHue, saturation: statusCompactingSaturation, brightness: statusCompactingBrightness)
    }
    var statusIdleColor: Color {
        Color.white.opacity(statusIdleOpacity)
    }

    func colorForState(_ state: PreviewState) -> Color {
        switch state {
        case .none: return .clear
        case .ready: return statusReadyColor
        case .working: return statusWorkingColor
        case .waiting: return statusWaitingColor
        case .compacting: return statusCompactingColor
        case .idle: return statusIdleColor
        }
    }

    func reset() {
        panelTintOpacity = 0.33
        panelCornerRadius = 22
        panelBorderOpacity = 0.36
        panelHighlightOpacity = 0.07
        panelTopHighlightOpacity = 0.14
        panelShadowOpacity = 0.00
        panelShadowRadius = 0
        panelShadowY = 0

        cardTintOpacity = 0.58
        cardCornerRadius = 13
        cardBorderOpacity = 0.28
        cardHighlightOpacity = 0.14
        cardHoverBorderOpacity = 0.37
        cardHoverHighlightOpacity = 0.16

        useEmphasizedMaterial = true
        materialType = 0

        statusReadyHue = 0.329
        statusReadySaturation = 1.00
        statusReadyBrightness = 1.00

        statusWorkingHue = 0.103
        statusWorkingSaturation = 1.00
        statusWorkingBrightness = 1.00

        statusWaitingHue = 0.026
        statusWaitingSaturation = 0.58
        statusWaitingBrightness = 1.00

        statusCompactingHue = 0.670
        statusCompactingSaturation = 0.50
        statusCompactingBrightness = 1.00

        statusIdleOpacity = 0.40

        rippleSpeed = 4.9
        rippleCount = 4
        rippleMaxOpacity = 1.00
        rippleLineWidth = 30.0
        rippleBlurAmount = 41.5
        rippleOriginX = 0.89
        rippleOriginY = 0.00
        rippleFadeInZone = 0.10
        rippleFadeOutPower = 4.0

        borderGlowInnerWidth = 0.49
        borderGlowOuterWidth = 2.88
        borderGlowInnerBlur = 0.5
        borderGlowOuterBlur = 1.5
        borderGlowBaseOpacity = 0.30
        borderGlowPulseIntensity = 0.50
        borderGlowRotationMultiplier = 0.50

        breathingDotSize = 12
        breathingDotShadowRadius = 0
        breathingGlowSize = 8
        breathingGlowBlur = 5
        breathingSpeed = 3.00
        breathingMinScale = 0.52
        breathingMinOpacity = 0.7
        breathingGlowMinScale = 0.80
        breathingGlowMaxScale = 1.46
        breathingGlowMinOpacity = 0.25
        breathingGlowMaxOpacity = 0.5
        breathingPhaseOffset = 0.0

        statusTextSize = 12
        statusTextWeight = 5
        statusTextSpacing = 4
        statusIdleTextOpacity = 0.55

        previewState = .none
    }

    func exportForLLM() -> String {
        """
        ## Tuned Visual Parameters for Claude HUD

        ### Panel (Main Window) Settings
        ```swift
        panelTintOpacity: \(String(format: "%.2f", panelTintOpacity))
        panelCornerRadius: \(String(format: "%.0f", panelCornerRadius))
        panelBorderOpacity: \(String(format: "%.2f", panelBorderOpacity))
        panelHighlightOpacity: \(String(format: "%.2f", panelHighlightOpacity))
        panelTopHighlightOpacity: \(String(format: "%.2f", panelTopHighlightOpacity))
        panelShadowOpacity: \(String(format: "%.2f", panelShadowOpacity))
        panelShadowRadius: \(String(format: "%.0f", panelShadowRadius))
        panelShadowY: \(String(format: "%.0f", panelShadowY))
        ```

        ### Card Settings
        ```swift
        cardTintOpacity: \(String(format: "%.2f", cardTintOpacity))
        cardCornerRadius: \(String(format: "%.0f", cardCornerRadius))
        cardBorderOpacity: \(String(format: "%.2f", cardBorderOpacity))
        cardHighlightOpacity: \(String(format: "%.2f", cardHighlightOpacity))
        cardHoverBorderOpacity: \(String(format: "%.2f", cardHoverBorderOpacity))
        cardHoverHighlightOpacity: \(String(format: "%.2f", cardHoverHighlightOpacity))
        ```

        ### Status Colors
        ```swift
        // Ready (Green)
        statusReady: Color(hue: \(String(format: "%.3f", statusReadyHue)), saturation: \(String(format: "%.2f", statusReadySaturation)), brightness: \(String(format: "%.2f", statusReadyBrightness)))

        // Working (Yellow/Orange)
        statusWorking: Color(hue: \(String(format: "%.3f", statusWorkingHue)), saturation: \(String(format: "%.2f", statusWorkingSaturation)), brightness: \(String(format: "%.2f", statusWorkingBrightness)))

        // Waiting (Lime)
        statusWaiting: Color(hue: \(String(format: "%.3f", statusWaitingHue)), saturation: \(String(format: "%.2f", statusWaitingSaturation)), brightness: \(String(format: "%.2f", statusWaitingBrightness)))

        // Compacting (Gold)
        statusCompacting: Color(hue: \(String(format: "%.3f", statusCompactingHue)), saturation: \(String(format: "%.2f", statusCompactingSaturation)), brightness: \(String(format: "%.2f", statusCompactingBrightness)))

        // Idle
        statusIdle: Color.white.opacity(\(String(format: "%.2f", statusIdleOpacity)))
        ```

        ### Ready Ripple
        ```swift
        rippleSpeed: \(String(format: "%.1f", rippleSpeed))
        rippleCount: \(rippleCount)
        rippleMaxOpacity: \(String(format: "%.2f", rippleMaxOpacity))
        rippleLineWidth: \(String(format: "%.1f", rippleLineWidth))
        rippleBlurAmount: \(String(format: "%.1f", rippleBlurAmount))
        rippleFadeInZone: \(String(format: "%.2f", rippleFadeInZone))
        rippleFadeOutPower: \(String(format: "%.1f", rippleFadeOutPower))
        rippleOriginX: \(String(format: "%.2f", rippleOriginX))
        rippleOriginY: \(String(format: "%.2f", rippleOriginY))
        ```

        ### Border Glow
        ```swift
        borderGlowInnerWidth: \(String(format: "%.2f", borderGlowInnerWidth))
        borderGlowOuterWidth: \(String(format: "%.2f", borderGlowOuterWidth))
        borderGlowInnerBlur: \(String(format: "%.1f", borderGlowInnerBlur))
        borderGlowOuterBlur: \(String(format: "%.1f", borderGlowOuterBlur))
        borderGlowBaseOpacity: \(String(format: "%.2f", borderGlowBaseOpacity))
        borderGlowPulseIntensity: \(String(format: "%.2f", borderGlowPulseIntensity))
        borderGlowRotationMultiplier: \(String(format: "%.2f", borderGlowRotationMultiplier))
        ```

        ### Breathing Dot
        ```swift
        breathingDotSize: \(String(format: "%.0f", breathingDotSize))
        breathingDotShadowRadius: \(String(format: "%.1f", breathingDotShadowRadius))
        breathingMinScale: \(String(format: "%.2f", breathingMinScale))
        breathingMinOpacity: \(String(format: "%.2f", breathingMinOpacity))
        breathingSpeed: \(String(format: "%.2f", breathingSpeed))
        breathingPhaseOffset: \(String(format: "%.2f", breathingPhaseOffset))
        breathingGlowSize: \(String(format: "%.0f", breathingGlowSize))
        breathingGlowBlur: \(String(format: "%.0f", breathingGlowBlur))
        breathingGlowMinScale: \(String(format: "%.2f", breathingGlowMinScale))
        breathingGlowMaxScale: \(String(format: "%.2f", breathingGlowMaxScale))
        breathingGlowMinOpacity: \(String(format: "%.2f", breathingGlowMinOpacity))
        breathingGlowMaxOpacity: \(String(format: "%.2f", breathingGlowMaxOpacity))
        ```

        ### Status Text Settings
        ```swift
        statusTextSize: \(String(format: "%.0f", statusTextSize))
        statusTextWeight: \(statusTextWeight)
        statusTextSpacing: \(String(format: "%.0f", statusTextSpacing))
        statusIdleTextOpacity: \(String(format: "%.2f", statusIdleTextOpacity))
        ```
        """
    }
}

struct GlassTuningPanel: View {
    @ObservedObject var config = GlassConfig.shared
    @Binding var isPresented: Bool
    @State private var copiedToClipboard = false
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            ScrollView {
                VStack(spacing: 12) {
                    switch selectedTab {
                    case 0: glassContent
                    case 1: statusColorsContent
                    case 2: effectsContent
                    case 3: previewContent
                    default: glassContent
                    }
                }
                .padding(12)
            }
            actionsSection
                .padding(12)
        }
        .frame(width: 300, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)

            Text("Visual Tuning")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            TuningTab(title: "Glass", icon: "square.on.square", isSelected: selectedTab == 0) {
                selectedTab = 0
            }
            TuningTab(title: "Colors", icon: "paintpalette", isSelected: selectedTab == 1) {
                selectedTab = 1
            }
            TuningTab(title: "Effects", icon: "sparkles", isSelected: selectedTab == 2) {
                selectedTab = 2
            }
            TuningTab(title: "Preview", icon: "play.circle", isSelected: selectedTab == 3) {
                selectedTab = 3
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.2))
    }

    private var glassContent: some View {
        VStack(spacing: 12) {
            TuningSection(title: "Panel Background") {
                TuningSlider(label: "Tint Opacity", value: $config.panelTintOpacity, range: 0...1)
                TuningSlider(label: "Corner Radius", value: $config.panelCornerRadius, range: 0...30)
                TuningSlider(label: "Border Opacity", value: $config.panelBorderOpacity, range: 0...1)
                TuningSlider(label: "Highlight", value: $config.panelHighlightOpacity, range: 0...0.3)
                TuningSlider(label: "Top Highlight", value: $config.panelTopHighlightOpacity, range: 0...0.5)
                TuningSlider(label: "Shadow Opacity", value: $config.panelShadowOpacity, range: 0...1)
                TuningSlider(label: "Shadow Radius", value: $config.panelShadowRadius, range: 0...50)
                TuningSlider(label: "Shadow Y", value: $config.panelShadowY, range: 0...30)
            }

            TuningSection(title: "Card Background") {
                TuningSlider(label: "Tint Opacity", value: $config.cardTintOpacity, range: 0...1)
                TuningSlider(label: "Corner Radius", value: $config.cardCornerRadius, range: 0...24)
                TuningSlider(label: "Border Opacity", value: $config.cardBorderOpacity, range: 0...1)
                TuningSlider(label: "Highlight", value: $config.cardHighlightOpacity, range: 0...0.3)
                TuningSlider(label: "Hover Border", value: $config.cardHoverBorderOpacity, range: 0...1)
                TuningSlider(label: "Hover Highlight", value: $config.cardHoverHighlightOpacity, range: 0...0.5)
            }

            TuningSection(title: "Material", isExpanded: false) {
                Picker("Material", selection: $config.materialType) {
                    ForEach(0..<GlassConfig.materialNames.count, id: \.self) { index in
                        Text(GlassConfig.materialNames[index]).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 11))

                Text("isEmphasized only affects .selection material (for sidebars)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                    .italic()
            }
        }
    }

    private var statusColorsContent: some View {
        VStack(spacing: 12) {
            StatusColorSection(
                title: "Ready",
                hue: $config.statusReadyHue,
                saturation: $config.statusReadySaturation,
                brightness: $config.statusReadyBrightness,
                color: config.statusReadyColor
            )

            StatusColorSection(
                title: "Working",
                hue: $config.statusWorkingHue,
                saturation: $config.statusWorkingSaturation,
                brightness: $config.statusWorkingBrightness,
                color: config.statusWorkingColor
            )

            StatusColorSection(
                title: "Waiting",
                hue: $config.statusWaitingHue,
                saturation: $config.statusWaitingSaturation,
                brightness: $config.statusWaitingBrightness,
                color: config.statusWaitingColor
            )

            StatusColorSection(
                title: "Compacting",
                hue: $config.statusCompactingHue,
                saturation: $config.statusCompactingSaturation,
                brightness: $config.statusCompactingBrightness,
                color: config.statusCompactingColor
            )

            TuningSection(title: "Idle") {
                HStack {
                    Circle()
                        .fill(config.statusIdleColor)
                        .frame(width: 12, height: 12)
                    Spacer()
                }
                TuningSlider(label: "Opacity", value: $config.statusIdleOpacity, range: 0...1)
            }
        }
    }

    private var effectsContent: some View {
        VStack(spacing: 12) {
            TuningSection(title: "Ready Ripple") {
                TuningSlider(label: "Speed (seconds)", value: $config.rippleSpeed, range: 1...10)
                TuningSlider(label: "Ring Count", value: Binding(
                    get: { Double(config.rippleCount) },
                    set: { config.rippleCount = Int($0) }
                ), range: 1...6)
                TuningSlider(label: "Max Opacity", value: $config.rippleMaxOpacity, range: 0...1)
                TuningSlider(label: "Line Width", value: $config.rippleLineWidth, range: 0.5...30)
                TuningSlider(label: "Blur Amount", value: $config.rippleBlurAmount, range: 0...60)
                TuningSlider(label: "Fade In Zone", value: $config.rippleFadeInZone, range: 0...0.5)
                TuningSlider(label: "Fade Out Power", value: $config.rippleFadeOutPower, range: 0.5...4)
                TuningSlider(label: "Origin X", value: $config.rippleOriginX, range: 0...1)
                TuningSlider(label: "Origin Y", value: $config.rippleOriginY, range: 0...1)
            }

            TuningSection(title: "Border Glow") {
                TuningSlider(label: "Inner Width", value: $config.borderGlowInnerWidth, range: 0.25...3)
                TuningSlider(label: "Outer Width", value: $config.borderGlowOuterWidth, range: 0.5...5)
                TuningSlider(label: "Inner Blur", value: $config.borderGlowInnerBlur, range: 0...3)
                TuningSlider(label: "Outer Blur", value: $config.borderGlowOuterBlur, range: 0...8)
                TuningSlider(label: "Base Opacity", value: $config.borderGlowBaseOpacity, range: 0...1)
                TuningSlider(label: "Pulse Intensity", value: $config.borderGlowPulseIntensity, range: 0...1)
                TuningSlider(label: "Rotation Speed", value: $config.borderGlowRotationMultiplier, range: 0...2)
            }

            TuningSection(title: "Breathing Dot") {
                TuningSlider(label: "Dot Size", value: $config.breathingDotSize, range: 3...20)
                TuningSlider(label: "Shadow Radius", value: $config.breathingDotShadowRadius, range: 0...6)
                TuningSlider(label: "Min Scale", value: $config.breathingMinScale, range: 0.3...1)
                TuningSlider(label: "Min Opacity", value: $config.breathingMinOpacity, range: 0.3...1)
                TuningSlider(label: "Speed (non-sync)", value: $config.breathingSpeed, range: 0.5...10)
                TuningSlider(label: "Phase Offset", value: $config.breathingPhaseOffset, range: 0...1)

                Text("Glow Settings")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)

                TuningSlider(label: "Glow Size", value: $config.breathingGlowSize, range: 4...40)
                TuningSlider(label: "Glow Blur", value: $config.breathingGlowBlur, range: 0...20)
                TuningSlider(label: "Glow Min Scale", value: $config.breathingGlowMinScale, range: 0.3...1)
                TuningSlider(label: "Glow Max Scale", value: $config.breathingGlowMaxScale, range: 1...3)
                TuningSlider(label: "Glow Min Opacity", value: $config.breathingGlowMinOpacity, range: 0...1)
                TuningSlider(label: "Glow Max Opacity", value: $config.breathingGlowMaxOpacity, range: 0...1)
            }

            TuningSection(title: "Status Text") {
                TuningSlider(label: "Font Size", value: $config.statusTextSize, range: 8...16)

                HStack {
                    Text("Weight")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Picker("", selection: $config.statusTextWeight) {
                        Text("Light").tag(3)
                        Text("Regular").tag(4)
                        Text("Medium").tag(5)
                        Text("Semibold").tag(6)
                        Text("Bold").tag(7)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                TuningSlider(label: "Dot Spacing", value: $config.statusTextSpacing, range: 2...12)
                TuningSlider(label: "Idle Opacity", value: $config.statusIdleTextOpacity, range: 0.2...1)
            }
        }
    }

    private var previewContent: some View {
        VStack(spacing: 16) {
            TuningSection(title: "Trigger State Preview") {
                Text("Click a state to preview it on all project cards")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 4)

                ForEach(PreviewState.allCases, id: \.self) { state in
                    StatePreviewButton(
                        state: state,
                        isSelected: config.previewState == state,
                        color: config.colorForState(state)
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            config.previewState = state
                        }
                    }
                }
            }

            TuningSection(title: "Live Preview") {
                VStack(spacing: 12) {
                    ForEach([PreviewState.ready, .working, .waiting, .compacting, .idle], id: \.self) { state in
                        HStack(spacing: 8) {
                            TunableBreathingDot(color: config.colorForState(state), config: config)
                            Text(state.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                            Circle()
                                .fill(config.colorForState(state))
                                .frame(width: 8, height: 8)
                                .shadow(color: config.colorForState(state).opacity(0.6), radius: 4)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 8) {
            Button(action: { config.reset() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Reset")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: copyToClipboard) {
                HStack(spacing: 4) {
                    Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(copiedToClipboard ? "Copied!" : "Export")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(config.exportForLLM(), forType: .string)

        withAnimation(.spring(response: 0.3)) {
            copiedToClipboard = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3)) {
                copiedToClipboard = false
            }
        }
    }
}

struct TuningTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(isSelected ? .orange : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Color.orange.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct StatusColorSection: View {
    let title: String
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    let color: Color

    var body: some View {
        TuningSection(title: title) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .shadow(color: color.opacity(0.6), radius: 4)
                Spacer()
            }
            TuningSlider(label: "Hue", value: $hue, range: 0...1)
            TuningSlider(label: "Saturation", value: $saturation, range: 0...1)
            TuningSlider(label: "Brightness", value: $brightness, range: 0...1)
        }
    }
}

struct StatePreviewButton: View {
    let state: PreviewState
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if state != .none {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                        .shadow(color: color.opacity(0.5), radius: 3)
                }
                Text(state.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                }
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.orange.opacity(0.2) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct TunableBreathingDot: View {
    let color: Color
    let config: GlassConfig
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: config.breathingGlowSize, height: config.breathingGlowSize)
                .scaleEffect(isAnimating ? config.breathingGlowMaxScale : config.breathingGlowMinScale)
                .opacity(isAnimating ? 0.25 : 0.5)

            Circle()
                .fill(color)
                .frame(width: config.breathingDotSize, height: config.breathingDotSize)
                .shadow(color: color.opacity(0.6), radius: 3)
                .scaleEffect(isAnimating ? config.breathingMinScale : 1.0)
                .opacity(isAnimating ? 0.7 : 1.0)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: config.breathingSpeed).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

struct TuningSection<Content: View>: View {
    let title: String
    let content: () -> Content
    @State private var isExpanded: Bool

    init(title: String, isExpanded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = State(initialValue: isExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.spring(response: 0.25)) { isExpanded.toggle() } }) {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.5))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 10) {
                    content()
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct TuningSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var displayValue: String {
        if range.upperBound <= 1 {
            return String(format: "%.2f", value)
        } else if range.upperBound <= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.0f", value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))

                Spacer()

                Text(displayValue)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
            }

            Slider(value: $value, in: range)
                .controlSize(.mini)
                .tint(.orange)
        }
    }
}

#endif
