import SwiftUI

struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool

    init(_ message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }

    static func error(_ message: String) -> ToastMessage {
        ToastMessage(message, isError: true)
    }
}

struct ToastView: View {
    let toast: ToastMessage
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(toast.isError ? .red.opacity(0.9) : .green.opacity(0.9))

            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        .scaleEffect(appeared ? 1 : 0.8)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                appeared = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                dismiss()
            }
        }
        .onTapGesture {
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}

struct ToastContainer: View {
    @Binding var toast: ToastMessage?

    var body: some View {
        VStack {
            Spacer()

            if let toast = toast {
                ToastView(toast: toast) {
                    self.toast = nil
                }
                .id(toast.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 20)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toast?.id)
    }
}
