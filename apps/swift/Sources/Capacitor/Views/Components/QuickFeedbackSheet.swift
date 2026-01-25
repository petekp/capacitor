import AppKit
import SwiftUI

struct QuickFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = QuickFeedbackDraft.defaults
    @State private var formSessionID = QuickFeedbackFunnel.makeSessionID()
    @State private var openGitHubIssue = false
    @State private var hasSubmitted = false
    @State private var completedFields: Set<String> = []
    @State private var didEmitOpened = false

    let onSubmit: (QuickFeedbackDraft, QuickFeedbackPreferences, String, Bool) -> Void

    private var canSubmit: Bool {
        draft.canSubmit
    }

    private var preferences: QuickFeedbackPreferences {
        QuickFeedbackPreferences.load()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Feedback")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                StockFeedbackTextArea(text: $draft.summary)
                    .frame(height: 80)
            }

            Toggle("Open a GitHub issue (optional)", isOn: $openGitHubIssue)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button(openGitHubIssue ? "Open GitHub Issue" : "Share feedback") {
                    var normalizedDraft = draft.normalized()
                    normalizedDraft.details = ""
                    normalizedDraft.expectedBehavior = ""
                    normalizedDraft.stepsToReproduce = ""
                    hasSubmitted = true
                    QuickFeedbackFunnel.emitSubmitAttempt(
                        sessionID: formSessionID,
                        draft: normalizedDraft,
                        preferences: preferences,
                    )
                    onSubmit(
                        normalizedDraft,
                        preferences,
                        formSessionID,
                        openGitHubIssue,
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .onChange(of: draft.summary) { _, newValue in
            emitFieldCompletedIfNeeded(field: "feedback", textValue: newValue)
        }
        .onAppear {
            guard !didEmitOpened else { return }
            didEmitOpened = true
            QuickFeedbackFunnel.emitOpened(sessionID: formSessionID, preferences: preferences)
        }
        .onDisappear {
            guard !hasSubmitted, draft.hasAnyContent else { return }
            QuickFeedbackFunnel.emitAbandoned(
                sessionID: formSessionID,
                draft: draft.normalized(),
                preferences: preferences,
                completionCount: max(completedFields.count, draft.completionCount),
            )
        }
        .padding(16)
        .frame(width: 392)
    }

    private func emitFieldCompletedIfNeeded(field: String, textValue: String? = nil) {
        if let textValue,
           textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return
        }

        guard !completedFields.contains(field) else { return }
        completedFields.insert(field)
        QuickFeedbackFunnel.emitFieldCompleted(
            sessionID: formSessionID,
            field: field,
            draft: draft.normalized(),
            preferences: preferences,
            completionCount: max(completedFields.count, draft.completionCount),
        )
    }
}

final class QuickFeedbackTextView: NSTextView {
    var onSelectNextKeyView: (() -> Void)?
    var onSelectPreviousKeyView: (() -> Void)?

    override func insertTab(_ sender: Any?) {
        if let onSelectNextKeyView {
            onSelectNextKeyView()
            return
        }
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if let onSelectPreviousKeyView {
            onSelectPreviousKeyView()
            return
        }
        window?.selectPreviousKeyView(sender)
    }
}

private struct StockFeedbackTextArea: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = QuickFeedbackTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.borderType = .bezelBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
