import SwiftUI

struct WorkBatchHomeSectionHeader: View {
    let section: WorkBatchHomeSection
    var onCaptureTask: (() -> Void)?

    @State private var isAddHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text(section.project.name)
                .font(AppTypography.label.weight(.semibold))
                .foregroundColor(.white.opacity(0.52))
                .lineLimit(1)
                .truncationMode(.tail)

            if section.batchCount > 0 {
                Text("\(section.batchCount)")
                    .font(AppTypography.badge)
                    .foregroundColor(.white.opacity(0.38))
                    .monospacedDigit()
            }

            if section.queuedTaskCount > 0 {
                Text("\(section.queuedTaskCount) queued")
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let onCaptureTask {
                Button(action: onCaptureTask) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(isAddHovered ? 0.72 : 0.45))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(isAddHovered ? 0.12 : 0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Task to \(section.project.name)")
                .help("Add Task")
                .onHover { hovering in
                    withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                        isAddHovered = hovering
                    }
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
    }
}

struct WorkBatchEmptyProjectRow: View {
    var body: some View {
        Text("No Work Batches yet")
            .font(AppTypography.bodySecondary)
            .foregroundStyle(.white.opacity(0.4))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
