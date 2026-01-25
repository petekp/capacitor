import SwiftUI

struct ScrollEdgeFadeStops {
    let topClear: CGFloat
    let topOpaque: CGFloat
    let bottomOpaque: CGFloat
    let bottomClear: CGFloat

    static func locations(
        height: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        topFade: CGFloat,
        bottomFade: CGFloat,
    ) -> ScrollEdgeFadeStops {
        guard height > 0 else {
            return ScrollEdgeFadeStops(topClear: 0, topOpaque: 0, bottomOpaque: 1, bottomClear: 1)
        }

        let topClear = clamp(topInset / height)
        let topOpaque = clamp((topInset + topFade) / height)
        let bottomClear = clamp((height - bottomInset) / height)
        let bottomOpaque = clamp((height - bottomInset - bottomFade) / height)

        let resolvedTopOpaque = max(topClear, topOpaque)
        let resolvedBottomOpaque = max(resolvedTopOpaque, min(bottomOpaque, bottomClear))
        let resolvedBottomClear = max(resolvedBottomOpaque, bottomClear)

        return ScrollEdgeFadeStops(
            topClear: topClear,
            topOpaque: resolvedTopOpaque,
            bottomOpaque: resolvedBottomOpaque,
            bottomClear: resolvedBottomClear,
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }
}

struct ScrollMaskLayout {
    static func scrollbarMaskWidth(preferredWidth: CGFloat, expandedWidth: CGFloat) -> CGFloat {
        max(0, max(preferredWidth, expandedWidth))
    }

    static func contentTrailingPadding(basePadding: CGFloat, scrollbarMaskWidth: CGFloat) -> CGFloat {
        max(basePadding, scrollbarMaskWidth)
    }

    static func sizes(totalWidth: CGFloat, scrollbarWidth: CGFloat) -> (content: CGFloat, scrollbar: CGFloat) {
        let clampedScrollbar = max(0, min(scrollbarWidth, totalWidth))
        let contentWidth = max(totalWidth - clampedScrollbar, 0)
        return (contentWidth, clampedScrollbar)
    }
}

struct ScrollEdgeFadeMask: View {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let topFade: CGFloat
    let bottomFade: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let stops = ScrollEdgeFadeStops.locations(
                height: geometry.size.height,
                topInset: topInset,
                bottomInset: bottomInset,
                topFade: topFade,
                bottomFade: bottomFade,
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: stops.topClear),
                    .init(color: .white, location: stops.topOpaque),
                    .init(color: .white, location: stops.bottomOpaque),
                    .init(color: .clear, location: stops.bottomClear),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom,
            )
        }
    }
}

private struct ProjectListScrollMaskModifier: ViewModifier {
    let scrollbarWidth: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let topFade: CGFloat
    let bottomFade: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                let sizes = ScrollMaskLayout.sizes(
                    totalWidth: proxy.size.width,
                    scrollbarWidth: scrollbarWidth,
                )

                HStack(spacing: 0) {
                    ScrollEdgeFadeMask(
                        topInset: topInset,
                        bottomInset: bottomInset,
                        topFade: topFade,
                        bottomFade: bottomFade,
                    )
                    .frame(width: sizes.content, height: proxy.size.height)

                    Color.white
                        .frame(width: sizes.scrollbar, height: proxy.size.height)
                }
            }
        }
    }
}

extension View {
    func scrollEdgeFadeMask(
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        topFade: CGFloat,
        bottomFade: CGFloat,
    ) -> some View {
        mask(
            ScrollEdgeFadeMask(
                topInset: topInset,
                bottomInset: bottomInset,
                topFade: topFade,
                bottomFade: bottomFade,
            ),
        )
    }

    func projectListScrollMask(
        scrollbarWidth: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        topFade: CGFloat,
        bottomFade: CGFloat,
    ) -> some View {
        modifier(
            ProjectListScrollMaskModifier(
                scrollbarWidth: scrollbarWidth,
                topInset: topInset,
                bottomInset: bottomInset,
                topFade: topFade,
                bottomFade: bottomFade,
            ),
        )
    }
}
