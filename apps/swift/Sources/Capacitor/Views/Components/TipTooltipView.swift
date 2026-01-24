// TipTooltipView.swift
//
// One-time educational tooltip for feature discoverability.
// Shown once after a user's first "Link Project" button click to hint
// that drag-and-drop is also available. Uses @AppStorage to persist
// the "has seen" flag across launches.
//
// Timing: Appears after the toast dismisses (if any) to avoid overlap.
// Auto-dismisses after 4 seconds, or on tap.

import SwiftUI

struct TipTooltipView: View {
    let message: String
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.yellow.opacity(0.9))

            Text(message)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                dismiss()
            }
        }
        .onTapGesture {
            dismiss()
        }
    }

    private func dismiss() {
        guard appeared else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}

struct TipTooltipContainer: View {
    @Binding var showTip: Bool
    let message: String

    var body: some View {
        VStack {
            Spacer()

            if showTip {
                TipTooltipView(message: message) {
                    showTip = false
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 20)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showTip)
    }
}
