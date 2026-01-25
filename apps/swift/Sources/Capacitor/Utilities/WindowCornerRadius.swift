import SwiftUI

enum WindowCornerRadius {
    static func value(floatingMode: Bool, config: GlassConfig = .shared) -> CGFloat {
        guard floatingMode else { return 0 }
        return CGFloat(config.panelCornerRadius)
    }
}
