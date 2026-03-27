import AppKit
import SwiftUI

struct MethodSelectorModalOverlay: View {
    let methods: [MethodTemplate]
    let onSelect: (MethodTemplate) -> Void
    let onDismiss: () -> Void

    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            scrimBackground
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            MethodSelectorView(
                methods: methods,
                onSelect: onSelect,
                onDismiss: onDismiss,
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
            installEscapeMonitor()
        }
        .onDisappear {
            removeEscapeMonitor()
        }
        .onExitCommand {
            onDismiss()
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

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                onDismiss()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}
