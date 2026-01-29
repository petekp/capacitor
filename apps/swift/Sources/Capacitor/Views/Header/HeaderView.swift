import SwiftUI
import AppKit

struct HeaderView: View {
    @Environment(\.floatingMode) private var floatingMode

    private let progressiveBlurHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            // Header content
            HStack {
                Spacer()
                AddProjectButton()
            }
            .padding(.horizontal, 12)
            .padding(.top, floatingMode ? 9 : 6)
            .padding(.bottom, 6)
            .background {
                if floatingMode {
                    VibrancyView(
                        material: .hudWindow,
                        blendingMode: .behindWindow,
                        isEmphasized: false,
                        forceDarkAppearance: true
                    )
                } else {
                    Color.hudBackground
                }
            }

            // Progressive blur zone - fades content below into the header
            ProgressiveBlurView(
                direction: .down,
                height: progressiveBlurHeight,
                material: floatingMode ? .hudWindow : .windowBackground
            )
            .allowsHitTesting(false)
        }
    }
}
