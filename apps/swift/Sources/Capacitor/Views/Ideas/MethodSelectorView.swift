import SwiftUI

/// A sheet that presents available method templates for an idea.
/// When a method is selected, it calls the `onSelect` callback with the method ID.
struct MethodSelectorView: View {
    let methods: [MethodTemplate]
    let onSelect: (MethodTemplate) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Run Method")
                    .font(AppTypography.sectionTitle.weight(.semibold))
                    .foregroundColor(.white)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.68))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityIdentifiers.methodSelectorDismissIdentifier)
            }

            Text("Choose how Capacitor should orchestrate this idea")
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(0.6))

            if methods.isEmpty {
                MethodSelectorEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(methods, id: \.id) { method in
                            MethodCard(method: method) {
                                onSelect(method)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 400, alignment: .leading)
        .frame(maxHeight: 500, alignment: .top)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(panelBorder)
        .shadow(color: .black.opacity(0.32), radius: 22, y: 14)
        .accessibilityIdentifier(AccessibilityIdentifiers.methodSelectorIdentifier)
    }

    private var panelBackground: some View {
        ZStack {
            VibrancyView(
                material: .popover,
                blendingMode: .behindWindow,
                isEmphasized: false,
                forceDarkAppearance: true,
            )

            Color.black.opacity(0.22)

            LinearGradient(
                colors: [
                    .white.opacity(0.12),
                    .white.opacity(0.04),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing,
            )

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.16), .clear],
                    startPoint: .top,
                    endPoint: .bottom,
                )
                .frame(height: 1)

                Spacer()
            }
        }
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(0.18),
                        .white.opacity(0.08),
                        .white.opacity(0.04),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing,
                ),
                lineWidth: 0.75,
            )
    }
}

private struct MethodCard: View {
    let method: MethodTemplate
    let onTap: () -> Void

    @State private var isHovered = false

    private var phaseCount: Int {
        method.phases.count
    }

    private var phaseCountLabel: String {
        "\(phaseCount) \(phaseCount == 1 ? "phase" : "phases")"
    }

    private var involvementLabel: String {
        switch method.defaultInvolvement {
        case .autonomous:
            "Autonomous"
        case .supervised:
            "Supervised"
        case .collaborative:
            "Collaborative"
        }
    }

    private var phaseSummary: String? {
        let names = method.phases.map(\.name).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: " -> ")
    }

    private var iconName: String {
        switch method.taskArchetype {
        case "implementation": "bolt.fill"
        case "feature": "arrow.triangle.branch"
        case "debugging": "ant.fill"
        case "greenfield": "hammer.fill"
        default: "gearshape.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.15 : 0.08))

                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isHovered ? .white : .white.opacity(0.76))
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(method.name)
                        .font(AppTypography.bodyMedium.weight(.medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(method.description)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        metadataBadge(involvementLabel)
                        metadataBadge(phaseCountLabel)
                    }
                    .padding(.top, 2)

                    if let phaseSummary {
                        HStack(spacing: 6) {
                            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))

                            Text(phaseSummary)
                                .font(AppTypography.monoCaption)
                                .foregroundColor(.white.opacity(0.46))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.top, 1)
                    }
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(isHovered ? 0.72 : 0.38))
                    .padding(.top, 10)
            }
            .padding(14)
            .background(
                DarkFrostedCard(
                    isHovered: isHovered,
                    tintOpacity: isHovered ? 0.14 : 0.18,
                    layoutMode: .vertical,
                ),
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isHovered ? 0.16 : 0.08),
                        lineWidth: 0.75,
                    ),
            )
            .scaleEffect(isHovered ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityIdentifiers.methodCardIdentifier(for: method.id))
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.86)) {
                isHovered = hovering
            }
        }
    }

    private func metadataBadge(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.caption.weight(.medium))
            .foregroundColor(.white.opacity(0.68))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(isHovered ? 0.14 : 0.08))
            .clipShape(Capsule())
    }
}

private struct MethodSelectorEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.white.opacity(0.38))

            Text("No methods available")
                .font(AppTypography.bodyMedium)
                .foregroundColor(.white.opacity(0.72))

            Text("Method templates will appear here when the registry is available.")
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.48))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 38)
        .padding(.horizontal, 16)
    }
}
