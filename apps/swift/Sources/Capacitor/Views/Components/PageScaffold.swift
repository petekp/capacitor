import AppKit
import SwiftUI

/// Composable full-page layout with a fixed header/footer overlay and a
/// masked ScrollView. Extracted from ProjectsView's proven pattern so
/// WelcomeView (and future pages) get the same gradient-edge masking,
/// scrollbar inset treatment, and floating-mode awareness.
///
/// Usage:
/// ```swift
/// PageScaffold {
///     // header (pinned to top)
///     Text("Title")
/// } content: {
///     // scrollable body
///     ForEach(items) { ... }
/// } footer: {
///     // footer (pinned to bottom)
///     Button("Continue") { ... }
/// }
/// ```
struct PageScaffold<Header: View, Content: View, Footer: View>: View {
    @Environment(\.floatingMode) private var floatingMode

    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    // MARK: - Layout values (matching ProjectsView)

    private var contentTopPadding: CGFloat {
        floatingMode ? 56 : 12
    }

    private var contentBottomPadding: CGFloat {
        floatingMode ? 64 : 8
    }

    private var edgeFadeHeight: CGFloat {
        floatingMode ? 30 : 0
    }

    private var topFade: CGFloat {
        contentTopPadding + edgeFadeHeight
    }

    private var bottomFade: CGFloat {
        contentBottomPadding + edgeFadeHeight
    }

    private var scrollbarInset: CGFloat {
        floatingMode ? WindowCornerRadius.value(floatingMode: floatingMode) : 0
    }

    var body: some View {
        let preferredScrollbarWidth = NSScroller.scrollerWidth(
            for: .regular,
            scrollerStyle: NSScroller.preferredScrollerStyle,
        )
        let expandedScrollbarWidth = NSScroller.scrollerWidth(
            for: .regular,
            scrollerStyle: .legacy,
        )
        let maskScrollbarWidth = ScrollMaskLayout.scrollbarMaskWidth(
            preferredWidth: preferredScrollbarWidth,
            expandedWidth: expandedScrollbarWidth,
        )

        ZStack {
            // Scrollable content layer
            ScrollView {
                content
                    .padding(.top, contentTopPadding)
                    .padding(.bottom, contentBottomPadding)
                    .padding(.horizontal, 16)
            }
            .projectListScrollMask(
                scrollbarWidth: maskScrollbarWidth,
                topFade: topFade,
                bottomFade: bottomFade,
            )
            .background(
                ScrollViewScrollerInsetsConfigurator(
                    topInset: scrollbarInset,
                    bottomInset: scrollbarInset,
                    hideTrack: true,
                ),
            )

            // Fixed header/footer overlay
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                Spacer()

                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .padding(.bottom, floatingMode ? 6 : 0)
            }
        }
    }
}
