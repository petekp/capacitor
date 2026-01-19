import SwiftUI
import Variablur

struct ProgressiveTopBlur: ViewModifier {
    let blurHeight: CGFloat
    let maxRadius: CGFloat
    let isEnabled: Bool

    init(blurHeight: CGFloat = 72, maxRadius: CGFloat = 20, isEnabled: Bool = true) {
        self.blurHeight = blurHeight
        self.maxRadius = maxRadius
        self.isEnabled = isEnabled
    }

    func body(content: Content) -> some View {
        content
            .variableBlur(
                radius: maxRadius,
                maxSampleCount: 12,
                verticalPassFirst: false
            ) { geometry, context in
                let fadeStart: CGFloat = blurHeight * 0.5
                let fadeEnd: CGFloat = blurHeight

                context.fill(
                    Path(CGRect(origin: .zero, size: geometry.size)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: fadeStart / geometry.size.height),
                            .init(color: .clear, location: fadeEnd / geometry.size.height)
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: geometry.size.height)
                    )
                )
            }
    }
}

extension View {
    func progressiveTopBlur(
        blurHeight: CGFloat = 72,
        maxRadius: CGFloat = 20,
        isEnabled: Bool = true
    ) -> some View {
        modifier(ProgressiveTopBlur(
            blurHeight: blurHeight,
            maxRadius: maxRadius,
            isEnabled: isEnabled
        ))
    }
}
