@testable import Capacitor
import XCTest

final class ScrollEdgeFadeMaskTests: XCTestCase {
    func testStopsIncludeInsetsAndFadeHeights() {
        let stops = ScrollEdgeFadeStops.locations(
            height: 200,
            topInset: 56,
            bottomInset: 64,
            topFade: 30,
            bottomFade: 30,
        )

        XCTAssertEqual(stops.topClear, 0.28, accuracy: 0.001)
        XCTAssertEqual(stops.topOpaque, 0.43, accuracy: 0.001)
        XCTAssertEqual(stops.bottomOpaque, 0.53, accuracy: 0.001)
        XCTAssertEqual(stops.bottomClear, 0.68, accuracy: 0.001)
    }

    func testStopsClampWhenFadesOverlap() {
        let stops = ScrollEdgeFadeStops.locations(
            height: 100,
            topInset: 60,
            bottomInset: 60,
            topFade: 30,
            bottomFade: 30,
        )

        XCTAssertEqual(stops.topClear, 0.6, accuracy: 0.001)
        XCTAssertEqual(stops.topOpaque, 0.9, accuracy: 0.001)
        XCTAssertEqual(stops.bottomOpaque, 0.9, accuracy: 0.001)
        XCTAssertEqual(stops.bottomClear, 0.9, accuracy: 0.001)
    }

    func testStopsHandleZeroHeight() {
        let stops = ScrollEdgeFadeStops.locations(
            height: 0,
            topInset: 20,
            bottomInset: 20,
            topFade: 20,
            bottomFade: 20,
        )

        XCTAssertEqual(stops.topClear, 0, accuracy: 0.001)
        XCTAssertEqual(stops.topOpaque, 0, accuracy: 0.001)
        XCTAssertEqual(stops.bottomOpaque, 1, accuracy: 0.001)
        XCTAssertEqual(stops.bottomClear, 1, accuracy: 0.001)
    }

    func testMaskLayoutReservesScrollbarWidth() {
        let sizes = ScrollMaskLayout.sizes(totalWidth: 300, scrollbarWidth: 14)

        XCTAssertEqual(sizes.content, 286, accuracy: 0.001)
        XCTAssertEqual(sizes.scrollbar, 14, accuracy: 0.001)
    }

    func testMaskLayoutClampsScrollbarWidth() {
        let sizes = ScrollMaskLayout.sizes(totalWidth: 10, scrollbarWidth: 20)

        XCTAssertEqual(sizes.content, 0, accuracy: 0.001)
        XCTAssertEqual(sizes.scrollbar, 10, accuracy: 0.001)
    }

    func testScrollbarMaskWidthUsesExpandedWidth() {
        let width = ScrollMaskLayout.scrollbarMaskWidth(preferredWidth: 6, expandedWidth: 14)

        XCTAssertEqual(width, 14, accuracy: 0.001)
    }

    func testContentTrailingPaddingReservesScrollbarLane() {
        let padding = ScrollMaskLayout.contentTrailingPadding(basePadding: 8, scrollbarMaskWidth: 14)

        XCTAssertEqual(padding, 14, accuracy: 0.001)
    }
}
