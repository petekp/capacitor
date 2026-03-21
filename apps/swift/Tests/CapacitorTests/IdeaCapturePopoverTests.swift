import AppKit
@testable import Capacitor
import XCTest

@MainActor
final class IdeaCapturePopoverTests: XCTestCase {
    func testTextAreaLayoutLeavesTopAndBottomScrimZones() {
        let frame = IdeaCaptureTextAreaLayout.frame(in: ideaCaptureTestWindowSize)

        XCTAssertEqual(frame.width, 500, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 60, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 440, accuracy: 0.001)
        XCTAssertEqual(frame.midX, ideaCaptureTestWindowSize.width / 2, accuracy: 0.001)
        XCTAssertTrue(frame.contains(CGPoint(x: ideaCaptureTestWindowSize.width / 2, y: ideaCaptureTestWindowSize.height / 2)))
        XCTAssertFalse(frame.contains(CGPoint(x: ideaCaptureTestWindowSize.width / 2, y: ideaCaptureTestWindowSize.height - 20)))
        XCTAssertFalse(frame.contains(CGPoint(x: ideaCaptureTestWindowSize.width / 2, y: 20)))
    }

    func testTextAreaLayoutHonorsHorizontalPaddingOnNarrowContainers() {
        let frame = IdeaCaptureTextAreaLayout.frame(in: CGSize(width: 260, height: 220))

        XCTAssertEqual(frame.minX, 48, accuracy: 0.001)
        XCTAssertEqual(frame.maxX, 212, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 60, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 160, accuracy: 0.001)
    }

    func testFocusControllerDefersFocusUntilTextViewHasWindow() {
        let focusController = TextViewFocusController()
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: ideaCaptureTestWindowSize))
        let textView = NSTextView(frame: scrollView.bounds)
        scrollView.documentView = textView

        focusController.attach(textView: textView, scrollView: scrollView)
        focusController.requestFocus()

        XCTAssertNil(textView.window)

        let window = TestWindow(
            contentRect: CGRect(origin: .zero, size: ideaCaptureTestWindowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        let container = NSView(frame: CGRect(origin: .zero, size: ideaCaptureTestWindowSize))
        window.contentView = container
        container.addSubview(scrollView)
        scrollView.frame = container.bounds

        focusController.viewDidMoveToWindow()
        pumpRunLoop(for: 0.05)

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testFocusControllerFocusesImmediatelyWhenWindowIsAvailable() {
        let focusController = TextViewFocusController()
        let window = TestWindow(
            contentRect: CGRect(origin: .zero, size: ideaCaptureTestWindowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        let container = NSView(frame: CGRect(origin: .zero, size: ideaCaptureTestWindowSize))
        let scrollView = NSScrollView(frame: container.bounds)
        let textView = NSTextView(frame: scrollView.bounds)

        scrollView.documentView = textView
        window.contentView = container
        container.addSubview(scrollView)

        focusController.attach(textView: textView, scrollView: scrollView)
        focusController.requestFocus()

        XCTAssertTrue(window.firstResponder === textView)
    }

    private func pumpRunLoop(for interval: TimeInterval) {
        let limit = Date().addingTimeInterval(interval)
        while RunLoop.main.run(mode: .default, before: limit), Date() < limit {}
    }
}

private let ideaCaptureTestWindowSize = CGSize(width: 800, height: 500)

private final class TestWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
