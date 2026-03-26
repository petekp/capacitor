import SwiftUI

struct IdeaDetailOverlay: View {
    let idea: Idea
    let onDismiss: () -> Void
    let onDelegate: (() -> Void)?
    let onRunMethod: (() -> Void)?
    let onRemove: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with dismiss
            HStack {
                Text("Added \(formatRelativeDate(idea.added))")
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.35))

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
                .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailDismissIdentifier)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Content
            VStack(alignment: .leading, spacing: 12) {
                Text(idea.title)
                    .font(AppTypography.sectionTitle.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if !idea.description.isEmpty {
                    Text(idea.description)
                        .font(AppTypography.bodyMedium)
                        .foregroundColor(.white.opacity(0.7))
                        .lineSpacing(3)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 20)

            // Actions
            HStack(spacing: 8) {
                if let onRunMethod {
                    Button(action: onRunMethod) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text("Run Method")
                                .font(AppTypography.caption.weight(.medium))
                        }
                        .foregroundColor(.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("idea_detail_run_method")
                }

                if let onDelegate {
                    Button(action: onDelegate) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text("Delegate")
                                .font(AppTypography.caption.weight(.medium))
                        }
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailDelegateIdentifier)
                }

                Spacer()

                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailRemoveIdentifier)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailIdentifier)
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                appeared = true
            }
        }
    }

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func formatRelativeDate(_ dateString: String) -> String {
        guard let date = parseISO8601Date(dateString) else {
            return dateString
        }
        return relativeString(from: date)
    }

    private func relativeString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: date, to: Date())

        if let days = components.day, days > 7 {
            return Self.mediumDateFormatter.string(from: date)
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
    let onDelegate: ((Idea) -> Void)?
    let onRunMethod: ((Idea) -> Void)?
    let onRemove: (Idea) -> Void

    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            if let idea {
                scrimBackground
                    .onTapGesture { onDismiss() }

                IdeaDetailOverlay(
                    idea: idea,
                    onDismiss: onDismiss,
                    onDelegate: onDelegate.map { handler in { handler(idea) } },
                    onRunMethod: onRunMethod.map { handler in { handler(idea) } },
                    onRemove: { onRemove(idea) },
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
                forceDarkAppearance: true,
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
