import SwiftUI
import AppKit

#if DEBUG

@MainActor
struct ShellMatrixPanel: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var shellStateStore = ShellStateStore()
    @State private var config = ShellMatrixConfig.shared
    @State private var selectedCategory: ParentAppCategory = .ide
    @State private var selectedParentApp: ParentAppType = .cursor
    @State private var copiedToClipboard = false
    @State private var panelSize = CGSize(width: 680, height: 760)

    private let containerCornerRadius: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
                .background(Color.white.opacity(0.1))
            detailArea
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background {
            DarkFrostedGlass()
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(TuningPanelWindowConfigurator())
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ParentAppCategory.allCases) { category in
                        MatrixCategoryRow(
                            category: category,
                            selectedCategory: $selectedCategory,
                            selectedParentApp: $selectedParentApp
                        )
                    }
                }
                .padding(8)
            }

            Spacer()

            sidebarFooter
        }
        .frame(width: 180)
    }

    private var sidebarHeader: some View {
        HStack {
            Text("Shell Matrix")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            if config.hasChanges {
                Text("\(config.modifiedCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.8))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 6) {
            Button(action: copyToClipboard) {
                HStack(spacing: 6) {
                    Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(copiedToClipboard ? "Copied!" : "Copy Changes")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            if config.hasChanges {
                Button(action: { config.resetAll() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                        Text("Reset All")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var detailArea: some View {
        VStack(spacing: 0) {
            detailHeader

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    LiveStateSection(shellStateStore: shellStateStore)
                    ScenarioListSection(
                        parentApp: selectedParentApp,
                        config: config
                    )
                }
            }
            .onAppear {
                shellStateStore.startPolling()
            }
            .onDisappear {
                shellStateStore.stopPolling()
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: containerCornerRadius,
                topTrailingRadius: containerCornerRadius
            )
        )
    }

    private var detailHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedCategory.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Text(selectedParentApp.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }

            Spacer()

            Button(action: { dismissWindow(id: "shell-matrix-panel") }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func copyToClipboard() {
        config.copyToClipboard()

        withAnimation(.spring(response: 0.3)) {
            copiedToClipboard = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3)) {
                copiedToClipboard = false
            }
        }
    }
}

private struct MatrixCategoryRow: View {
    let category: ParentAppCategory
    @Binding var selectedCategory: ParentAppCategory
    @Binding var selectedParentApp: ParentAppType
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 12)

                    Image(systemName: category.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))

                    Text(category.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))

                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(category.parentApps) { parentApp in
                        MatrixSubcategoryRow(
                            parentApp: parentApp,
                            isSelected: selectedParentApp == parentApp,
                            onSelect: {
                                selectedCategory = category
                                selectedParentApp = parentApp
                            }
                        )
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}

private struct MatrixSubcategoryRow: View {
    let parentApp: ParentAppType
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: parentApp.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.5))

                Text(parentApp.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.7))

                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#endif
