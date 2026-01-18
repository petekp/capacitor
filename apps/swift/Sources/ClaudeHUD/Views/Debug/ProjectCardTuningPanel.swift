import SwiftUI

#if DEBUG

enum CardInteractionState: String, CaseIterable {
    case idle = "Idle"
    case hover = "Hover"
    case pressed = "Pressed"
}

struct ProjectCardTuningPanel: View {
    @ObservedObject var glassConfig = GlassConfig.shared
    @Binding var isPresented: Bool

    @State private var selectedState: CardInteractionState = .hover
    @State private var copiedToClipboard = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 12) {
                    interactionContent
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)

            actionsSection
                .padding(10)
        }
        .frame(width: 320, height: 520)
        .background(Color.hudBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.hudBorder, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap")
                .font(AppTypography.labelMedium)
                .foregroundColor(.hudAccent)

            Text("Card Interaction")
                .font(AppTypography.cardTitle)
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            Text("TACTILE")
                .font(AppTypography.badge)
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.hudCard.opacity(0.6))
    }

    private var interactionContent: some View {
        VStack(spacing: 12) {
            stateSelector
            cardInteractionControls
        }
    }

    private var stateSelector: some View {
        HStack(spacing: 6) {
            ForEach(CardInteractionState.allCases, id: \.self) { state in
                Button(action: { withAnimation(.spring(response: 0.25)) { selectedState = state } }) {
                    VStack(spacing: 4) {
                        Image(systemName: iconForState(state))
                            .font(AppTypography.label)
                        Text(state.rawValue)
                            .font(AppTypography.captionSmall.weight(.medium))
                    }
                    .foregroundColor(selectedState == state ? .white : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selectedState == state ? Color.hudAccent.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selectedState == state ? Color.hudAccent.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.hudCard.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func iconForState(_ state: CardInteractionState) -> String {
        switch state {
        case .idle: return "hand.raised"
        case .hover: return "cursorarrow"
        case .pressed: return "hand.tap.fill"
        }
    }

    // MARK: - Card Interaction Controls

    @ViewBuilder
    private var cardInteractionControls: some View {
        switch selectedState {
        case .idle:
            TuningSection(title: "Idle State") {
                TuningSlider(label: "Scale", value: $glassConfig.cardIdleScale, range: 0.9...1.1)
                TuningSlider(label: "Shadow Opacity", value: $glassConfig.cardIdleShadowOpacity, range: 0...0.5)
                TuningSlider(label: "Shadow Radius", value: $glassConfig.cardIdleShadowRadius, range: 0...20)
                TuningSlider(label: "Shadow Y", value: $glassConfig.cardIdleShadowY, range: 0...10)
            }

        case .hover:
            TuningSection(title: "Hover State") {
                TuningSlider(label: "Scale", value: $glassConfig.cardHoverScale, range: 0.9...1.1)

                Text("Spring Animation")
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)

                TuningSlider(label: "Response", value: $glassConfig.cardHoverSpringResponse, range: 0.05...0.5)
                TuningSlider(label: "Damping", value: $glassConfig.cardHoverSpringDamping, range: 0.3...1.0)

                Text("Shadow")
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)

                TuningSlider(label: "Shadow Opacity", value: $glassConfig.cardHoverShadowOpacity, range: 0...0.5)
                TuningSlider(label: "Shadow Radius", value: $glassConfig.cardHoverShadowRadius, range: 0...30)
                TuningSlider(label: "Shadow Y", value: $glassConfig.cardHoverShadowY, range: 0...15)
            }

        case .pressed:
            TuningSection(title: "Pressed State") {
                TuningSlider(label: "Scale", value: $glassConfig.cardPressedScale, range: 0.85...1.0)

                Text("Spring Animation")
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)

                TuningSlider(label: "Response", value: $glassConfig.cardPressedSpringResponse, range: 0.05...0.3)
                TuningSlider(label: "Damping", value: $glassConfig.cardPressedSpringDamping, range: 0.3...1.0)

                Text("Shadow")
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)

                TuningSlider(label: "Shadow Opacity", value: $glassConfig.cardPressedShadowOpacity, range: 0...0.3)
                TuningSlider(label: "Shadow Radius", value: $glassConfig.cardPressedShadowRadius, range: 0...10)
                TuningSlider(label: "Shadow Y", value: $glassConfig.cardPressedShadowY, range: 0...5)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 8) {
            Button(action: resetInteractionValues) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(AppTypography.label.weight(.semibold))
                    Text("Reset")
                        .font(AppTypography.labelMedium)
                }
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.hudCard)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: copyToClipboard) {
                HStack(spacing: 4) {
                    Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                        .font(AppTypography.label.weight(.semibold))
                    Text(copiedToClipboard ? "Copied!" : "Export")
                        .font(AppTypography.labelMedium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    LinearGradient(
                        colors: [Color.hudAccent, Color.hudAccentDark],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private func resetInteractionValues() {
        glassConfig.cardIdleScale = 1.0
        glassConfig.cardIdleShadowOpacity = 0.08
        glassConfig.cardIdleShadowRadius = 4.0
        glassConfig.cardIdleShadowY = 2.0
        glassConfig.cardHoverScale = 0.99
        glassConfig.cardHoverSpringResponse = 0.2
        glassConfig.cardHoverSpringDamping = 0.8
        glassConfig.cardHoverShadowOpacity = 0.2
        glassConfig.cardHoverShadowRadius = 12.0
        glassConfig.cardHoverShadowY = 4.0
        glassConfig.cardPressedScale = 0.97
        glassConfig.cardPressedSpringResponse = 0.12
        glassConfig.cardPressedSpringDamping = 0.6
        glassConfig.cardPressedShadowOpacity = 0.12
        glassConfig.cardPressedShadowRadius = 2.0
        glassConfig.cardPressedShadowY = 1.0
    }

    private func copyToClipboard() {
        let export = exportInteractionValues()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(export, forType: .string)

        withAnimation(.spring(response: 0.3)) {
            copiedToClipboard = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3)) {
                copiedToClipboard = false
            }
        }
    }

    private func exportInteractionValues() -> String {
        let defaults: [(String, Double, Double)] = [
            ("cardIdleScale", 1.0, glassConfig.cardIdleScale),
            ("cardIdleShadowOpacity", 0.08, glassConfig.cardIdleShadowOpacity),
            ("cardIdleShadowRadius", 4.0, glassConfig.cardIdleShadowRadius),
            ("cardIdleShadowY", 2.0, glassConfig.cardIdleShadowY),
            ("cardHoverScale", 0.99, glassConfig.cardHoverScale),
            ("cardHoverSpringResponse", 0.2, glassConfig.cardHoverSpringResponse),
            ("cardHoverSpringDamping", 0.8, glassConfig.cardHoverSpringDamping),
            ("cardHoverShadowOpacity", 0.2, glassConfig.cardHoverShadowOpacity),
            ("cardHoverShadowRadius", 12.0, glassConfig.cardHoverShadowRadius),
            ("cardHoverShadowY", 4.0, glassConfig.cardHoverShadowY),
            ("cardPressedScale", 0.97, glassConfig.cardPressedScale),
            ("cardPressedSpringResponse", 0.12, glassConfig.cardPressedSpringResponse),
            ("cardPressedSpringDamping", 0.6, glassConfig.cardPressedSpringDamping),
            ("cardPressedShadowOpacity", 0.12, glassConfig.cardPressedShadowOpacity),
            ("cardPressedShadowRadius", 2.0, glassConfig.cardPressedShadowRadius),
            ("cardPressedShadowY", 1.0, glassConfig.cardPressedShadowY),
        ]

        let changed = defaults.filter { abs($0.1 - $0.2) > 0.001 }

        if changed.isEmpty {
            return "## Card Interaction Parameters\n\nNo changes from defaults."
        }

        var output = "## Card Interaction Parameters\n\n### Changed Values\n```swift\n"
        for (name, defaultVal, currentVal) in changed {
            output += "\(name): \(String(format: "%.2f", defaultVal)) → \(String(format: "%.2f", currentVal))\n"
        }
        output += "```"

        return output
    }
}

#endif
