import SwiftUI

struct RuntimeStatusCard: View {
    let status: RuntimeStatus
    let onRetry: () -> Void

    @State private var isHovered = false

    private var cardColor: Color {
        status.isHealthy ? .green : .orange
    }

    var body: some View {
        if status.isEnabled, !status.isHealthy {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(cardColor)

                    Text("Runtime offline")
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.8))

                    Spacer()

                    Button(action: onRetry) {
                        Text("Retry")
                            .font(AppTypography.captionSmall.weight(.semibold))
                            .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.7))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isHovered = hovering
                        }
                    }
                }

                Divider()
                    .background(cardColor.opacity(0.2))

                VStack(alignment: .leading, spacing: 4) {
                    detailRow(label: "Status", value: status.message)
                    if let pid = status.pid {
                        detailRow(label: "PID", value: "\(pid)")
                    }
                    if let version = status.version {
                        detailRow(label: "Version", value: version)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(cardColor.opacity(0.1)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(cardColor.opacity(0.2), lineWidth: 0.5),
            )
        } else {
            EmptyView()
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(AppTypography.captionSmall)
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 55, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
