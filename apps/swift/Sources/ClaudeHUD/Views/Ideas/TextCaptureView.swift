import SwiftUI

struct TextCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ideaText: String = ""
    @State private var captureError: String?
    @State private var isCapturing = false
    @State private var showDiscardConfirmation = false
    @FocusState private var isTextFieldFocused: Bool

    let projectPath: String
    let projectName: String
    let onCapture: (String) -> Result<Void, Error>

    private var hasUnsavedText: Bool {
        !ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Capture Idea")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Button(action: { attemptDismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                Text(projectName)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $ideaText)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .frame(minHeight: 100, maxHeight: 200)
                    .focused($isTextFieldFocused)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                captureError != nil ? Color.red.opacity(0.5) : Color.white.opacity(0.2),
                                lineWidth: 1
                            )
                    )
                    .disabled(isCapturing)

                if ideaText.isEmpty {
                    Text("Type your idea here. Keep it brief - you can expand on it later with Claude.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }

            if let error = captureError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.9))
                    Spacer()
                    Button("Dismiss") {
                        captureError = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    attemptDismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.7))
                .disabled(isCapturing)

                Spacer()

                if isCapturing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }

                Button("Capture") {
                    captureIdea()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!hasUnsavedText || isCapturing)
            }
        }
        .padding(24)
        .frame(width: 500, height: captureError != nil ? 360 : 320)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
        .confirmationDialog(
            "Discard idea?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved text that will be lost.")
        }
    }

    private func attemptDismiss() {
        if hasUnsavedText {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func captureIdea() {
        let trimmed = ideaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCapturing = true
        captureError = nil

        let result = onCapture(trimmed)

        isCapturing = false

        switch result {
        case .success:
            dismiss()
        case .failure(let error):
            captureError = error.localizedDescription
        }
    }
}
