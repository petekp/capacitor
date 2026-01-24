import SwiftUI
import AppKit

struct IdeaCaptureOverlay: View {
    @Binding var isPresented: Bool
    @Binding var shouldFocus: Bool
    let projectName: String
    let onCapture: (String) -> Result<Void, Error>

    @State private var ideaText: String = ""
    @State private var captureError: String?
    @State private var isCapturing = false
    @State private var returnMonitor: Any?
    @State private var showingSuccess = false
    @State private var placeholder: String = placeholders.randomElement()!
    @State private var isTextFieldFocused = false

    private static let placeholders = [
        "What's your idea?",
        "Dream big...",
        "I'm all ears",
        "What's next?",
        "Make something happen"
    ]

    private enum Layout {
        static let maxTextWidth: CGFloat = 500
        static let horizontalPadding: CGFloat = 48
        static let cornerPadding: CGFloat = 24

        static let maxFontSize: CGFloat = 28
        static let minFontSize: CGFloat = 18
        static let fontScaleStartLength: Int = 50
        static let fontScaleEndLength: Int = 200
    }

    private var hasText: Bool {
        !ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var dynamicFontSize: CGFloat {
        let length = ideaText.count

        guard length > Layout.fontScaleStartLength else {
            return Layout.maxFontSize
        }

        guard length < Layout.fontScaleEndLength else {
            return Layout.minFontSize
        }

        let progress = CGFloat(length - Layout.fontScaleStartLength) / CGFloat(Layout.fontScaleEndLength - Layout.fontScaleStartLength)
        return Layout.maxFontSize - (progress * (Layout.maxFontSize - Layout.minFontSize))
    }

    var body: some View {
        ZStack {
            // Full-bleed text area - clickable everywhere
            textArea
                .onTapGesture {
                    focusTextArea()
                }

            // Corner elements overlay
            VStack {
                HStack {
                    // Top-left: Project name
                    Text(projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(Layout.cornerPadding)

                    Spacer()

                    // Top-right: Cancel button
                    Button(action: cancel) {
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

                // Error banner in the center-bottom area
                if let error = captureError {
                    errorBanner(error)
                        .frame(maxWidth: Layout.maxTextWidth)
                        .padding(.horizontal, Layout.horizontalPadding)
                        .padding(.bottom, 80)
                }

                HStack {
                    // Bottom-left: Keyboard hints
                    Text("⏎ Save  ⇧⏎ Save & add another  ⎋ Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(Layout.cornerPadding)

                    Spacer()

                    // Bottom-right: Save button
                    Button(action: captureAndClose) {
                        HStack(spacing: showingSuccess ? 0 : 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                            if !showingSuccess {
                                Text("Save")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                        .foregroundColor(showingSuccess ? .white : (hasText ? .white : .white.opacity(0.4)))
                        .padding(.horizontal, showingSuccess ? 14 : 18)
                        .padding(.vertical, 10)
                        .background(showingSuccess ? Color.green : (hasText ? Color.blue : Color.white.opacity(0.1)))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: showingSuccess)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasText || isCapturing || showingSuccess)
                    .padding(Layout.cornerPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            installReturnMonitor()
        }
        .onDisappear {
            removeReturnMonitor()
        }
        .onChange(of: shouldFocus) { _, newValue in
            if newValue {
                focusTextArea()
            }
        }
    }

    private func focusTextArea() {
        isTextFieldFocused = true
    }

    private func installReturnMonitor() {
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Return key (keyCode 36)
            if event.keyCode == 36 {
                let hasShift = event.modifierFlags.contains(.shift)

                if hasShift {
                    captureAndClear()
                } else {
                    captureAndClose()
                }
                return nil // Consume the event
            }
            return event
        }
    }

    private func removeReturnMonitor() {
        if let monitor = returnMonitor {
            NSEvent.removeMonitor(monitor)
            returnMonitor = nil
        }
    }

    private var textArea: some View {
        ZStack {
            // Full-bleed centered TextEditor with dynamic font scaling
            CenteredTextEditor(
                text: $ideaText,
                isFocused: $isTextFieldFocused,
                fontSize: dynamicFontSize,
                textColor: .white,
                placeholderColor: .white.withAlphaComponent(0.3),
                isDisabled: isCapturing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 60)
            .padding(.bottom, 60)

            // Centered placeholder (always at max size)
            if ideaText.isEmpty {
                Text(placeholder)
                    .font(.system(size: Layout.maxFontSize, weight: .regular))
                    .foregroundColor(.white.opacity(0.3))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.red)
            Text(error)
                .font(.system(size: 14))
                .foregroundColor(.red.opacity(0.9))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func captureAndClose() {
        guard capture() else { return }
        showSuccess {
            isPresented = false
        }
    }

    private func captureAndClear() {
        guard capture() else { return }
        showSuccess {
            ideaText = ""
            showingSuccess = false
            focusTextArea()
        }
    }

    private func showSuccess(then action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            showingSuccess = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            action()
        }
    }

    private func capture() -> Bool {
        let trimmed = ideaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        isCapturing = true
        captureError = nil

        let result = onCapture(trimmed)

        isCapturing = false

        switch result {
        case .success:
            return true
        case .failure(let error):
            captureError = error.localizedDescription
            return false
        }
    }

    private func cancel() {
        isPresented = false
    }
}

struct IdeaCaptureModalOverlay: View {
    @Binding var isPresented: Bool
    let projectName: String
    var originFrame: CGRect?
    var containerSize: CGSize
    let onCapture: (String) -> Result<Void, Error>

    @Environment(\.floatingMode) private var floatingMode
    @State private var escapeMonitor: Any?
    @State private var isVisible = false
    @State private var animatedIn = false
    @State private var shouldFocusTextArea = false

    private var cornerRadius: CGFloat {
        floatingMode ? 22 : 0
    }

    private var anchorPoint: UnitPoint {
        guard let origin = originFrame, origin != .zero, containerSize.width > 0, containerSize.height > 0 else {
            return .center
        }

        // origin is already in contentView coordinate space
        let unitX = origin.midX / containerSize.width
        let unitY = origin.midY / containerSize.height

        return UnitPoint(
            x: max(0, min(1, unitX)),
            y: max(0, min(1, unitY))
        )
    }

    var body: some View {
        ZStack {
            if isVisible {
                scrimBackground
                    .opacity(animatedIn ? 1 : 0)
                    .onTapGesture {
                        isPresented = false
                    }

                IdeaCaptureOverlay(
                    isPresented: $isPresented,
                    shouldFocus: $shouldFocusTextArea,
                    projectName: projectName,
                    onCapture: onCapture
                )
                .scaleEffect(animatedIn ? 1 : 0.3, anchor: anchorPoint)
                .opacity(animatedIn ? 1 : 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
            // Handle case where isPresented is already true on mount
            if isPresented {
                isVisible = true
                installKeyboardMonitors()
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        animatedIn = true
                    } completion: {
                        shouldFocusTextArea = true
                    }
                }
            }
        }
        .onChange(of: isPresented) { _, newValue in
            if newValue {
                // Show view, then animate in
                isVisible = true
                shouldFocusTextArea = false
                installKeyboardMonitors()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    animatedIn = true
                } completion: {
                    shouldFocusTextArea = true
                }
            } else {
                // Animate out, then hide view
                shouldFocusTextArea = false
                removeKeyboardMonitors()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    animatedIn = false
                } completion: {
                    isVisible = false
                }
            }
        }
        .onDisappear {
            removeKeyboardMonitors()
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

    private func installKeyboardMonitors() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                isPresented = false
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitors() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

// Keep the old name as an alias for compatibility
typealias IdeaCapturePopover = IdeaCaptureOverlay

// MARK: - NSView Extension for finding TextEditor's NSTextView

extension NSView {
    func findTextView() -> NSTextView? {
        if let textView = self as? NSTextView {
            return textView
        }
        for subview in subviews {
            if let found = subview.findTextView() {
                return found
            }
        }
        return nil
    }
}

// MARK: - Vertically Centered Text Editor

struct CenteredTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var fontSize: CGFloat
    var textColor: NSColor
    var placeholderColor: NSColor
    var isDisabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = CenteredNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .white
        textView.isEditable = !isDisabled
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 48, height: 0)

        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        // Set direct properties
        textView.font = font
        textView.textColor = textColor
        textView.alignment = .center
        textView.defaultParagraphStyle = paragraphStyle

        // Set typing attributes for new text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.typingAttributes = attributes

        if !text.isEmpty {
            textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CenteredNSTextView else { return }

        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        // Set direct properties
        textView.font = font
        textView.textColor = textColor
        textView.isEditable = !isDisabled

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        textView.typingAttributes = attributes

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
        } else if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }

        // Handle focus
        if isFocused {
            DispatchQueue.main.async {
                if let window = scrollView.window {
                    window.makeFirstResponder(textView)
                }
            }
        }

        textView.needsLayout = true
        textView.needsDisplay = true
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CenteredTextEditor
        weak var textView: NSTextView?

        init(_ parent: CenteredTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }
    }
}

class CenteredNSTextView: NSTextView {
    override func layout() {
        super.layout()
        centerTextVertically()
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else {
            return super.intrinsicContentSize
        }
        manager.ensureLayout(for: container)
        let rect = manager.usedRect(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: rect.height + textContainerInset.height * 2)
    }

    private func centerTextVertically() {
        guard let container = textContainer,
              let manager = layoutManager,
              let scrollView = enclosingScrollView else { return }

        manager.ensureLayout(for: container)
        let textHeight = manager.usedRect(for: container).height
        let viewHeight = scrollView.contentView.bounds.height

        let verticalInset = max(0, (viewHeight - textHeight) / 2)
        textContainerInset = NSSize(width: 48, height: verticalInset)
    }

    override func didChangeText() {
        super.didChangeText()
        centerTextVertically()
    }
}
