import SwiftUI

#if DEBUG
    struct RuntimeStatusBadge: View {
        let status: RuntimeStatus

        private var statusText: String {
            status.isHealthy ? "Runtime ok" : "Runtime offline"
        }

        private var statusColor: Color {
            status.isHealthy ? .green : .orange
        }

        var body: some View {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(AppTypography.captionSmall.weight(.semibold))
                        .foregroundColor(.white.opacity(0.85))
                }

                if let pid = status.pid {
                    Text("PID \(pid)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(statusColor.opacity(0.2), lineWidth: 0.5),
            )
        }
    }
#endif
