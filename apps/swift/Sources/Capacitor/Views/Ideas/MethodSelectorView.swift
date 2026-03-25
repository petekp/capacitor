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
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Text("Choose a workflow for this idea")
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(0.5))

            VStack(spacing: 8) {
                ForEach(methods, id: \.id) { method in
                    MethodCard(method: method) {
                        onSelect(method)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.hudBackground.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1),
                ),
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
            HStack(spacing: 14) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isHovered ? .white : .white.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(isHovered ? 0.15 : 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(method.name)
                        .font(AppTypography.bodyMedium.weight(.medium))
                        .foregroundColor(.white)

                    Text(method.description)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()

                Text("\(phaseCount) \(phaseCount == 1 ? "phase" : "phases")")
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0.04)),
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
