import AppKit
import SwiftUI

#if DEBUG

    enum TuningCategory: String, CaseIterable, Identifiable {
        case panel = "Panel"
        case projectCard = "Project Card"
        case logo = "Logo"
        case statusColors = "Status Colors"

        var id: String {
            rawValue
        }

        var icon: String {
            switch self {
            case .panel: "rectangle"
            case .projectCard: "rectangle.on.rectangle"
            case .logo: "textformat"
            case .statusColors: "paintpalette"
            }
        }

        var subcategories: [TuningSubcategory] {
            switch self {
            case .panel:
                [.panelBackground, .panelMaterial, .emptyStateGlow]
            case .projectCard:
                [.appearance, .cardMaterial, .layout, .interactions, .stateTransitions, .stateEffects]
            case .logo:
                [.logoAppearance]
            case .statusColors:
                [.allStates]
            }
        }
    }

    enum TuningSubcategory: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case cardMaterial = "Card Material"
        case layout = "Layout"
        case interactions = "Interactions"
        case stateTransitions = "Transitions"
        case stateEffects = "State Effects"
        case panelBackground = "Background"
        case panelMaterial = "Panel Material"
        case emptyStateGlow = "Empty State Glow"
        case logoAppearance = "Size & Opacity"
        case allStates = "All States"

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .cardMaterial, .panelMaterial: "Material"
            case .emptyStateGlow: "Empty State"
            default: rawValue
            }
        }

        var icon: String {
            switch self {
            case .appearance: "paintbrush"
            case .cardMaterial: "cube.transparent"
            case .layout: "rectangle.3.group"
            case .interactions: "hand.tap"
            case .stateTransitions: "timer"
            case .stateEffects: "sparkles"
            case .panelBackground: "square.fill"
            case .panelMaterial: "cube.transparent"
            case .emptyStateGlow: "sparkle"
            case .logoAppearance: "textformat.size"
            case .allStates: "circle.hexagongrid"
            }
        }

        var parent: TuningCategory {
            switch self {
            case .appearance, .cardMaterial, .layout, .interactions, .stateTransitions, .stateEffects: .projectCard
            case .panelBackground, .panelMaterial, .emptyStateGlow: .panel
            case .logoAppearance: .logo
            case .allStates: .statusColors
            }
        }
    }

    struct UITuningPanel: View {
        @Environment(\.dismissWindow) private var dismissWindow
        private let config = GlassConfig.shared
        @State private var selectedCategory: TuningCategory = .panel
        @State private var selectedSubcategory: TuningSubcategory = .panelBackground
        @State private var panelSize: CGSize = .init(width: 580, height: 720)
        @State private var copiedToClipboard = false

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

        // MARK: - Sidebar

        private var sidebar: some View {
            VStack(spacing: 0) {
                sidebarHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(TuningCategory.allCases) { category in
                            CategoryRow(
                                category: category,
                                selectedCategory: $selectedCategory,
                                selectedSubcategory: $selectedSubcategory,
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
                Text("UI Tuning")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }

        private var sidebarFooter: some View {
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
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5),
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }

        // MARK: - Detail Area

        private var detailArea: some View {
            VStack(spacing: 0) {
                detailHeader

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        detailContent
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: containerCornerRadius,
                    topTrailingRadius: containerCornerRadius,
                ),
            )
        }

        private var detailHeader: some View {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedCategory.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Text(selectedSubcategory.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }

                Spacer()

                Button(action: { dismissWindow(id: "ui-tuning-panel") }) {
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

        @ViewBuilder
        private var detailContent: some View {
            switch selectedSubcategory {
            case .appearance:
                CardAppearanceSection(config: config)
            case .cardMaterial:
                CardMaterialSection(config: config)
            case .layout:
                CardLayoutSection(config: config)
            case .interactions:
                CardInteractionsSection(config: config)
            case .stateTransitions:
                StateTransitionsSection(config: config)
            case .stateEffects:
                CardStateEffectsSection(config: config)
            case .panelBackground:
                PanelBackgroundSection(config: config)
            case .panelMaterial:
                PanelMaterialSection(config: config)
            case .emptyStateGlow:
                EmptyStateGlowSection(config: config)
            case .logoAppearance:
                LogoAppearanceSection(config: config)
            case .allStates:
                StatusColorsSection(config: config)
            }
        }

        // MARK: - Export

        private func copyToClipboard() {
            let export = config.exportForLLM()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(export, forType: .string)

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

    // MARK: - Category Row

    private struct CategoryRow: View {
        let category: TuningCategory
        @Binding var selectedCategory: TuningCategory
        @Binding var selectedSubcategory: TuningSubcategory
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
                        ForEach(category.subcategories) { sub in
                            SubcategoryRow(
                                subcategory: sub,
                                isSelected: selectedSubcategory == sub,
                                onSelect: {
                                    selectedCategory = category
                                    selectedSubcategory = sub
                                },
                            )
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }

    private struct SubcategoryRow: View {
        let subcategory: TuningSubcategory
        let isSelected: Bool
        let onSelect: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: subcategory.icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.5))

                    Text(subcategory.displayName)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.7))

                    Spacer()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.06) : Color.clear)),
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    // MARK: - Window Configurator

    struct TuningPanelWindowConfigurator: NSViewRepresentable {
        func makeNSView(context _: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                configureWindow(view.window)
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context _: Context) {
            DispatchQueue.main.async {
                configureWindow(nsView.window)
            }
        }

        private func configureWindow(_ window: NSWindow?) {
            guard let window else { return }

            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.titled)
            window.isMovableByWindowBackground = true
            window.titlebarSeparatorStyle = .none

            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }

#endif
