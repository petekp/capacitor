import SwiftUI

struct IdeaDetailOverlay: View {
    let idea: Idea
    let onDismiss: () -> Void
    let onRemove: () -> Void

    @State private var appeared = false

    private enum Layout {
        static let contentPadding: CGFloat = 32
        static let cornerPadding: CGFloat = 24
        static let maxContentWidth: CGFloat = 500
    }

    var body: some View {
        ZStack {
            // Main content - centered
            VStack(alignment: .leading, spacing: 24) {
                Text(idea.title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(4)

                if !idea.description.isEmpty {
                    Text(idea.description)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.white.opacity(0.8))
                        .lineSpacing(4)
                        .lineLimit(12)
                }
            }
            .frame(maxWidth: Layout.maxContentWidth, alignment: .leading)
            .padding(Layout.contentPadding)

            // Corner elements
            VStack {
                HStack {
                    Spacer()

                    // Top-right: Dismiss button
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(Layout.cornerPadding)
                }

                Spacer()

                HStack {
                    // Bottom-left: Timestamp
                    Text("Added \(formatRelativeDate(idea.added))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(Layout.cornerPadding)

                    Spacer()

                    // Bottom-right: Remove button
                    Button(action: onRemove) {
                        HStack(spacing: 8) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .medium))
                            Text("Remove")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.red.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(Layout.cornerPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                appeared = true
            }
        }
    }

    private func formatRelativeDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: dateString) {
            return relativeString(from: date)
        }

        let fallbackFormatter = ISO8601DateFormatter()
        if let date = fallbackFormatter.date(from: dateString) {
            return relativeString(from: date)
        }

        return dateString
    }

    private func relativeString(from date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day, .hour, .minute], from: date, to: now)

        if let days = components.day, days > 7 {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        } else if let days = components.day, days > 0 {
            return "\(days)d ago"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h ago"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m ago"
        } else {
            return "just now"
        }
    }
}

struct IdeaDetailModalOverlay: View {
    let idea: Idea?
    let anchorFrame: CGRect?
    let onDismiss: () -> Void
    let onRemove: (Idea) -> Void

    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            if let idea = idea {
                scrimBackground
                    .onTapGesture { onDismiss() }

                IdeaDetailOverlay(
                    idea: idea,
                    onDismiss: onDismiss,
                    onRemove: { onRemove(idea) }
                )
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.92), value: idea != nil)
        .onChange(of: idea != nil) { _, isPresented in
            if isPresented {
                installEscapeMonitor()
            } else {
                removeEscapeMonitor()
            }
        }
        .onDisappear {
            removeEscapeMonitor()
        }
    }

    private var scrimBackground: some View {
        ZStack {
            Color.black.opacity(0.5)

            VibrancyView(
                material: .fullScreenUI,
                blendingMode: .behindWindow,
                isEmphasized: false,
                forceDarkAppearance: true
            )
            .opacity(0.4)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                onDismiss()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}
