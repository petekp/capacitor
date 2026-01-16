import SwiftUI

struct CompactProjectCardView: View {
    let project: Project
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToRecent: () -> Void
    let onRemove: () -> Void
    var showSeparator: Bool = true

    @State private var isHovered = false
    @State private var isReviveHovered = false

    private let rowHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.white.opacity(isHovered ? 0.8 : 0.5))
                    .lineLimit(1)

                Spacer()

                Button(action: onMoveToRecent) {
                    Text("Revive")
                        .font(AppTypography.labelMedium)
                        .foregroundColor(.white.opacity(isReviveHovered ? 0.9 : 0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(isReviveHovered ? 0.15 : 0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.1)) {
                        isReviveHovered = hovering
                    }
                }
            }
            .frame(height: rowHeight)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }

            if showSeparator {
                Divider()
                    .background(Color.white.opacity(0.08))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button(action: onTap) {
                Label("Open in Terminal", systemImage: "terminal")
            }
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onMoveToRecent) {
                Label("Move to In Progress", systemImage: "arrow.up.circle")
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove from HUD", systemImage: "trash")
            }
        }
    }
}
