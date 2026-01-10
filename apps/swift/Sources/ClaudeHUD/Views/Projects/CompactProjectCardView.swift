import SwiftUI

struct CompactProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let isManuallyDormant: Bool
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToRecent: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()

                    Text(relativeTime(from: project.lastActive))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))

                    Button(action: onInfoTap) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(isHovered ? 0.5 : 0.2))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                }

                if let workingOn = projectStatus?.workingOn ?? sessionState?.workingOn, !workingOn.isEmpty {
                    Text(workingOn)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered ? Color.hudCard.opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? Color.hudBorder : Color.clear, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(isHovered ? 0.25 : 0))
                    .frame(width: 2)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
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
            if isManuallyDormant {
                Divider()
                Button(action: onMoveToRecent) {
                    Label("Move to Recent", systemImage: "sun.max")
                }
            }
        }
    }
}
