import AppKit
import SwiftUI

enum TaskCaptureSurfaceCopy {
    static let cardActionTitle = "Task"
    static let cardActionAccessibilityLabel = "Add task to this project"
    static let cardActionHelp = "Add task"

    static let placeholders = [
        "What should Capacitor do?",
        "Describe the task...",
        "What needs doing?",
        "What should change?",
        "Give Capacitor a task",
    ]

    static let keyboardHint = "⏎ Add Task  ⇧⏎ Add Task & keep adding  ⎋ Cancel"
    static let submitTitle = "Add Task"
    static let emptyQueueTitle = "No tasks queued"
    static let emptyQueueHint = "Hover over a project card and click \"+ Task\" to add one"

    static let userFacingStrings: [String] = [
        cardActionTitle,
        cardActionAccessibilityLabel,
        cardActionHelp,
        keyboardHint,
        submitTitle,
        emptyQueueTitle,
        emptyQueueHint,
    ] + placeholders
}

struct IdeaCaptureTextAreaLayout {
    static let maxWidth: CGFloat = 500
    static let horizontalPadding: CGFloat = 48
    static let verticalPadding: CGFloat = 60

    static func frame(in size: CGSize) -> CGRect {
        let width = max(0, min(maxWidth, size.width - (horizontalPadding * 2)))
        let height = max(0, size.height - (verticalPadding * 2))
        return CGRect(
            x: (size.width - width) / 2,
            y: verticalPadding,
            width: width,
            height: height,
        )
    }
}

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
    @State private var placeholder: String = TaskCaptureSurfaceCopy.placeholders.randomElement()!
    @State private var isTextFieldFocused = false

    private enum Layout {
        static let maxTextWidth = IdeaCaptureTextAreaLayout.maxWidth
        static let horizontalPadding = IdeaCaptureTextAreaLayout.horizontalPadding
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
            textArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            topBar
        }
        .overlay(alignment: .bottom) {
            bottomBar
        }
        .onAppear {
            installReturnMonitor()
            DispatchQueue.main.async {
                focusTextArea()
            }
        }
        .onDisappear {
            removeReturnMonitor()
        }
        .onChange(of: shouldFocus) { _, newValue in
            if newValue {
                focusTextArea()
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.ideaCaptureOverlayIdentifier)
    }

    private var topBar: some View {
        HStack {
            Text(projectName)
                .font(AppTypography.bodyMedium)
                .foregroundColor(.white.opacity(0.4))

            Spacer()

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(Layout.cornerPadding)
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if let error = captureError {
                errorBanner(error)
                    .frame(maxWidth: Layout.maxTextWidth)
                    .padding(.horizontal, Layout.horizontalPadding)
            }

            HStack {
                Text(TaskCaptureSurfaceCopy.keyboardHint)
                    .font(AppTypography.bodyMedium)
                    .foregroundColor(.white.opacity(0.4))

                Spacer()

                Button(action: captureAndClose) {
                    HStack(spacing: showingSuccess ? 0 : 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                        if !showingSuccess {
                            Text(TaskCaptureSurfaceCopy.submitTitle)
                                .font(AppTypography.cardTitle)
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
            }
            .padding(.horizontal, Layout.cornerPadding)
        }
        .padding(.bottom, Layout.cornerPadding)
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
        GeometryReader { geometry in
            let frame = IdeaCaptureTextAreaLayout.frame(in: geometry.size)

            ZStack {
                CenteredTextEditor(
                    text: $ideaText,
                    isFocused: $isTextFieldFocused,
                    fontSize: dynamicFontSize,
                    textColor: .white,
                    placeholderColor: .white.withAlphaComponent(0.3),
                    isDisabled: isCapturing,
                )
                .frame(width: frame.width, height: frame.height)

                if ideaText.isEmpty {
                    Text(placeholder)
                        .font(.system(size: Layout.maxFontSize, weight: .regular))
                        .foregroundColor(.white.opacity(0.3))
                        .frame(width: frame.width)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.red)
            Text(error)
                .font(AppTypography.body)
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
        case let .failure(error):
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
        WindowCornerRadius.value(floatingMode: floatingMode)
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
            y: max(0, min(1, unitY)),
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
                    onCapture: onCapture,
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
                forceDarkAppearance: true,
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

final class TextViewFocusController {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var hasPendingFocus = false
    private var retryGeneration = 0
    private var hasScheduledRetry = false
    private let retryDelays: [TimeInterval]

    init(retryDelays: [TimeInterval] = [0, 0.05, 0.15, 0.35, 0.75]) {
        self.retryDelays = retryDelays
    }

    func attach(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
    }

    @discardableResult
    func requestFocus() -> Bool {
        attemptFocus(scheduleRetryOnFailure: true)
    }

    private func attemptFocus(scheduleRetryOnFailure: Bool) -> Bool {
        guard let textView else {
            hasPendingFocus = true
            return false
        }

        guard let window = textView.window ?? scrollView?.window else {
            hasPendingFocus = true
            return false
        }

        hasPendingFocus = false

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        if window.canBecomeKey, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }

        if window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }

        let didFocus = window.firstResponder === textView
        hasPendingFocus = !didFocus

        if !didFocus, scheduleRetryOnFailure {
            scheduleFocusRetries()
        }

        return didFocus
    }

    func viewDidMoveToWindow() {
        guard hasPendingFocus else { return }

        DispatchQueue.main.async { [weak self] in
            self?.requestFocus()
        }
    }

    private func scheduleFocusRetries() {
        guard !hasScheduledRetry else { return }

        hasScheduledRetry = true
        retryGeneration += 1

        let generation = retryGeneration
        let delays = retryDelays.isEmpty ? [0] : retryDelays
        let lastRetryIndex = delays.index(before: delays.endIndex)

        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, retryGeneration == generation else { return }
                guard hasPendingFocus else {
                    hasScheduledRetry = false
                    return
                }

                let didFocus = attemptFocus(scheduleRetryOnFailure: false)
                if didFocus || index == lastRetryIndex {
                    hasScheduledRetry = false
                }
            }
        }
    }
}

final class FocusAwareScrollView: NSScrollView {
    var onDidMoveToWindow: (() -> Void)?
    var onMouseDown: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

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
        let scrollView = FocusAwareScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.onDidMoveToWindow = {
            context.coordinator.scrollViewDidMoveToWindow()
        }
        scrollView.onMouseDown = {
            context.coordinator.requestFocus()
        }

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
            .paragraphStyle: paragraphStyle,
        ]
        textView.typingAttributes = attributes

        if !text.isEmpty {
            textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }

        scrollView.documentView = textView
        scrollView.setAccessibilityIdentifier(AccessibilityIdentifiers.ideaCaptureTextAreaIdentifier)
        context.coordinator.attach(textView: textView, scrollView: scrollView)

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
            .paragraphStyle: paragraphStyle,
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

        if isFocused {
            context.coordinator.requestFocus()
        }

        textView.needsLayout = true
        textView.needsDisplay = true
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CenteredTextEditor
        weak var textView: NSTextView?
        let focusController = TextViewFocusController()

        init(_ parent: CenteredTextEditor) {
            self.parent = parent
        }

        func attach(textView: NSTextView, scrollView: NSScrollView) {
            self.textView = textView
            focusController.attach(textView: textView, scrollView: scrollView)
        }

        func requestFocus() {
            focusController.requestFocus()
        }

        func scrollViewDidMoveToWindow() {
            focusController.viewDidMoveToWindow()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func textDidEndEditing(_: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }
    }
}

class CenteredNSTextView: NSTextView {
    override var acceptsFirstResponder: Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

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
