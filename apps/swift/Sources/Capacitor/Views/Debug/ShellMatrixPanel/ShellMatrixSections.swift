import SwiftUI

#if DEBUG

// MARK: - Design Tokens

private enum MatrixTokens {
    enum Text {
        static let primary = Color.white.opacity(0.9)
        static let secondary = Color.white.opacity(0.6)
        static let tertiary = Color.white.opacity(0.4)
        static let muted = Color.white.opacity(0.5)
    }

    enum Surface {
        static let card = Color.white.opacity(0.03)
        static let cardModified = Color.orange.opacity(0.05)
        static let cardActive = Color.green.opacity(0.08)
        static let headerOverlay = Color.black.opacity(0.5)
    }

    enum Border {
        static let subtle = Color.white.opacity(0.06)
        static let hover = Color.white.opacity(0.12)
        static let modified = Color.orange.opacity(0.2)
        static let active = Color.green.opacity(0.25)
        static let muted = Color.white.opacity(0.08)
    }

    enum Badge {
        static let backgroundOpacity = 0.15
        static let foregroundOpacity = 0.9
    }

    enum Spacing {
        static let cardPadding: CGFloat = 12
        static let sectionHorizontal: CGFloat = 16
        static let sectionVertical: CGFloat = 12
        static let headerVertical: CGFloat = 6
    }

    enum Radius {
        static let card: CGFloat = 8
        static let badge: CGFloat = 4
    }
}

// MARK: - Live State Section

@MainActor
struct LiveStateSection: View {
    @Bindable var shellStateStore: ShellStateStore

    private var currentScenario: ShellScenario? {
        guard let shell = shellStateStore.mostRecentShell else { return nil }
        let shellCount = shellStateStore.state?.shells.count ?? 0
        return ShellScenario.fromLiveState(shell: shell.entry, shellCount: shellCount)
    }

    private var shellDetails: (pid: String, cwd: String, tty: String)? {
        guard let shell = shellStateStore.mostRecentShell else { return nil }
        return (shell.pid, shell.entry.cwd, shell.entry.tty)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let scenario = currentScenario, let details = shellDetails {
                    liveStateCard(scenario: scenario, details: details)
                } else {
                    noShellCard
                }
            }
            .padding(.horizontal, MatrixTokens.Spacing.sectionHorizontal)
            .padding(.vertical, MatrixTokens.Spacing.sectionVertical)
        } header: {
            stickyHeader
        }
    }

    private var stickyHeader: some View {
        HStack {
            Text("LIVE STATE")
                .font(.caption2.weight(.semibold))
                .foregroundColor(MatrixTokens.Text.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Spacer()

            if currentScenario != nil {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Active")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.green)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Shell active")
            }
        }
        .padding(.horizontal, MatrixTokens.Spacing.sectionHorizontal)
        .padding(.vertical, MatrixTokens.Spacing.headerVertical)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                VibrancyView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    isEmphasized: true,
                    forceDarkAppearance: true
                )
                MatrixTokens.Surface.headerOverlay
            }
        )
    }

    private func liveStateCard(scenario: ShellScenario, details: (pid: String, cwd: String, tty: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundColor(.green)
                    .font(.subheadline)

                Text(scenario.shortDescription)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(MatrixTokens.Text.primary)

                Spacer()
            }

            HStack(spacing: 6) {
                DimensionBadge(label: scenario.context.badge, color: scenario.context == .tmux ? .purple : .blue)
                DimensionBadge(label: scenario.multiplicity.badge, color: .gray)
            }

            VStack(alignment: .leading, spacing: 4) {
                DetailRow(label: "PID", value: details.pid)
                DetailRow(label: "CWD", value: details.cwd)
                DetailRow(label: "TTY", value: details.tty)
            }
            .padding(.top, 4)
        }
        .padding(MatrixTokens.Spacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: MatrixTokens.Radius.card)
                .fill(MatrixTokens.Surface.cardActive)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MatrixTokens.Radius.card)
                .strokeBorder(MatrixTokens.Border.active, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Active shell: \(scenario.shortDescription), PID \(details.pid)")
    }

    private var noShellCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .foregroundColor(MatrixTokens.Text.tertiary)
                .font(.subheadline)

            Text("No active shell detected")
                .font(.caption.weight(.medium))
                .foregroundColor(MatrixTokens.Text.muted)

            Spacer()
        }
        .padding(MatrixTokens.Spacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: MatrixTokens.Radius.card)
                .fill(MatrixTokens.Surface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MatrixTokens.Radius.card)
                .strokeBorder(MatrixTokens.Border.muted, lineWidth: 0.5)
        )
        .accessibilityLabel("No active shell detected")
    }
}

// MARK: - Scenario List Section

@MainActor
struct ScenarioListSection: View {
    let parentApp: ParentAppType
    @Bindable var config: ShellMatrixConfig

    private var scenarios: [ShellScenario] {
        ScenarioGenerator.generatePracticalScenarios(for: parentApp)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(scenarios) { scenario in
                    ScenarioRow(
                        scenario: scenario,
                        config: config
                    )
                }
            }
            .padding(.horizontal, MatrixTokens.Spacing.sectionHorizontal)
            .padding(.vertical, MatrixTokens.Spacing.sectionVertical)
        } header: {
            scenarioHeader
        }
    }

    private var scenarioHeader: some View {
        HStack {
            Text("SCENARIOS")
                .font(.caption2.weight(.semibold))
                .foregroundColor(MatrixTokens.Text.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Spacer()

            Text("\(scenarios.count) configurations")
                .font(.caption2.weight(.medium))
                .foregroundColor(MatrixTokens.Text.tertiary)
        }
        .padding(.horizontal, MatrixTokens.Spacing.sectionHorizontal)
        .padding(.vertical, MatrixTokens.Spacing.headerVertical)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                VibrancyView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    isEmphasized: true,
                    forceDarkAppearance: true
                )
                MatrixTokens.Surface.headerOverlay
            }
        )
    }
}

// MARK: - Scenario Row

@MainActor
struct ScenarioRow: View {
    let scenario: ShellScenario
    @Bindable var config: ShellMatrixConfig
    @State private var isHovered = false

    private var behavior: ScenarioBehavior {
        config.behavior(for: scenario)
    }

    private var isOverridden: Bool {
        config.isOverridden(scenario)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            badgeRow
            pickerSection
        }
        .padding(MatrixTokens.Spacing.cardPadding)
        .background(backgroundFill)
        .overlay(borderOverlay)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(scenario.displayName) scenario\(isOverridden ? ", modified" : "")")
    }

    private var headerRow: some View {
        HStack {
            Text(scenario.displayName)
                .font(.caption.weight(.medium))
                .foregroundColor(MatrixTokens.Text.primary)

            if isOverridden {
                modifiedBadge
            }

            Spacer()

            if isOverridden {
                resetButton
            }
        }
    }

    private var modifiedBadge: some View {
        Text("Modified")
            .font(.caption2.weight(.semibold))
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(MatrixTokens.Badge.backgroundOpacity))
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }

    private var resetButton: some View {
        Button(action: { config.resetBehavior(for: scenario) }) {
            Image(systemName: "arrow.counterclockwise")
                .font(.caption2.weight(.medium))
                .foregroundColor(MatrixTokens.Text.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset \(scenario.displayName) to default")
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            DimensionBadge(label: scenario.context.badge, color: scenario.context == .tmux ? .purple : .blue)
            DimensionBadge(label: scenario.multiplicity.badge, color: .gray)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Context: \(scenario.context.badge), \(scenario.multiplicity.badge)")
    }

    private var pickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StrategyPickerRow(
                label: "Action",
                strategy: behavior.primaryStrategy,
                includeNone: false,
                scenarioName: scenario.displayName,
                onStrategyChange: { newValue in
                    var newBehavior = behavior
                    newBehavior.primaryStrategy = newValue
                    config.setBehavior(newBehavior, for: scenario)
                }
            )

            StrategyPickerRow(
                label: "Fallback",
                strategy: behavior.fallbackStrategy ?? .skip,
                includeNone: true,
                scenarioName: scenario.displayName,
                onStrategyChange: { newValue in
                    var newBehavior = behavior
                    newBehavior.fallbackStrategy = newValue == .skip ? nil : newValue
                    config.setBehavior(newBehavior, for: scenario)
                }
            )
        }
    }

    private var backgroundFill: some View {
        RoundedRectangle(cornerRadius: MatrixTokens.Radius.card)
            .fill(isOverridden ? MatrixTokens.Surface.cardModified : MatrixTokens.Surface.card)
    }

    private var borderOverlay: some View {
        let borderColor: Color
        if isOverridden {
            borderColor = MatrixTokens.Border.modified
        } else if isHovered {
            borderColor = MatrixTokens.Border.hover
        } else {
            borderColor = MatrixTokens.Border.subtle
        }
        return RoundedRectangle(cornerRadius: MatrixTokens.Radius.card)
            .strokeBorder(borderColor, lineWidth: 0.5)
    }
}

// MARK: - Strategy Picker Row (Fixed: removed duplicated @State)

private struct StrategyPickerRow: View {
    let label: String
    let strategy: ActivationStrategy
    let includeNone: Bool
    let scenarioName: String
    let onStrategyChange: (ActivationStrategy) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(MatrixTokens.Text.secondary)
                .frame(minWidth: 50, alignment: .leading)

            strategyPicker

            Spacer()

            Text(strategy.description)
                .font(.caption2)
                .foregroundColor(MatrixTokens.Text.tertiary)
                .lineLimit(1)
        }
    }

    private var strategyPicker: some View {
        Picker(label, selection: Binding(
            get: { strategy },
            set: { onStrategyChange($0) }
        )) {
            if includeNone {
                Text("None").tag(ActivationStrategy.skip)
            }
            ForEach(filteredStrategies, id: \.self) { strat in
                Text(strat.displayName).tag(strat)
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 120)
        .labelsHidden()
        .accessibilityLabel("\(label) strategy for \(scenarioName)")
    }

    private var filteredStrategies: [ActivationStrategy] {
        ActivationStrategy.allCases.filter { $0 != .skip || !includeNone }
    }
}

// MARK: - Reusable Components

struct DimensionBadge: View {
    let label: String
    var color: Color = .blue

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium).monospaced())
            .foregroundColor(color.opacity(MatrixTokens.Badge.foregroundOpacity))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(MatrixTokens.Badge.backgroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: MatrixTokens.Radius.badge))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(MatrixTokens.Text.tertiary)
                .frame(minWidth: 30, alignment: .leading)

            Text(value)
                .font(.caption2.monospaced())
                .foregroundColor(MatrixTokens.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

#endif
