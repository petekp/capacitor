import SwiftUI

#if DEBUG

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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } header: {
            stickyHeader
        }
    }

    private var stickyHeader: some View {
        HStack {
            Text("LIVE STATE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.5)

            Spacer()

            if currentScenario != nil {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Active")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                VibrancyView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    isEmphasized: true,
                    forceDarkAppearance: true
                )
                Color.black.opacity(0.5)
            }
        )
    }

    private func liveStateCard(scenario: ShellScenario, details: (pid: String, cwd: String, tty: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))

                Text(scenario.shortDescription)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var noShellCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .foregroundColor(.white.opacity(0.4))
                .font(.system(size: 14))

            Text("No active shell detected")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } header: {
            scenarioHeader
        }
    }

    private var scenarioHeader: some View {
        HStack {
            Text("SCENARIOS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.5)

            Spacer()

            Text("\(scenarios.count) configurations")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                VibrancyView(
                    material: .hudWindow,
                    blendingMode: .behindWindow,
                    isEmphasized: true,
                    forceDarkAppearance: true
                )
                Color.black.opacity(0.5)
            }
        )
    }
}

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
        .padding(12)
        .background(backgroundFill)
        .overlay(borderOverlay)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var headerRow: some View {
        HStack {
            Text(scenario.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))

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
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15))
            .clipShape(Capsule())
    }

    private var resetButton: some View {
        Button(action: { config.resetBehavior(for: scenario) }) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            DimensionBadge(label: scenario.context.badge, color: scenario.context == .tmux ? .purple : .blue)
            DimensionBadge(label: scenario.multiplicity.badge, color: .gray)
        }
    }

    private var pickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StrategyPickerRow(
                label: "Action",
                strategy: behavior.primaryStrategy,
                includeNone: false
            ) { newValue in
                var newBehavior = behavior
                newBehavior.primaryStrategy = newValue
                config.setBehavior(newBehavior, for: scenario)
            }

            StrategyPickerRow(
                label: "Fallback",
                strategy: behavior.fallbackStrategy ?? .skip,
                includeNone: true
            ) { newValue in
                var newBehavior = behavior
                newBehavior.fallbackStrategy = newValue == .skip ? nil : newValue
                config.setBehavior(newBehavior, for: scenario)
            }
        }
    }

    private var backgroundFill: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isOverridden ? Color.orange.opacity(0.05) : Color.white.opacity(0.03))
    }

    private var borderOverlay: some View {
        let borderColor: Color
        if isOverridden {
            borderColor = Color.orange.opacity(0.2)
        } else if isHovered {
            borderColor = Color.white.opacity(0.12)
        } else {
            borderColor = Color.white.opacity(0.06)
        }
        return RoundedRectangle(cornerRadius: 8)
            .strokeBorder(borderColor, lineWidth: 0.5)
    }
}

private struct StrategyPickerRow: View {
    let label: String
    let strategy: ActivationStrategy
    let includeNone: Bool
    let onStrategyChange: (ActivationStrategy) -> Void

    @State private var selectedStrategy: ActivationStrategy

    init(label: String, strategy: ActivationStrategy, includeNone: Bool, onStrategyChange: @escaping (ActivationStrategy) -> Void) {
        self.label = label
        self.strategy = strategy
        self.includeNone = includeNone
        self.onStrategyChange = onStrategyChange
        self._selectedStrategy = State(initialValue: strategy)
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 50, alignment: .leading)

            strategyPicker

            Spacer()

            Text(selectedStrategy.description)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
        }
        .onChange(of: strategy) { _, newValue in
            selectedStrategy = newValue
        }
    }

    private var strategyPicker: some View {
        Picker("", selection: $selectedStrategy) {
            if includeNone {
                Text("None").tag(ActivationStrategy.skip)
            }
            ForEach(filteredStrategies, id: \.self) { strat in
                Text(strat.displayName).tag(strat)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 140)
        .labelsHidden()
        .onChange(of: selectedStrategy) { _, newValue in
            onStrategyChange(newValue)
        }
    }

    private var filteredStrategies: [ActivationStrategy] {
        ActivationStrategy.allCases.filter { $0 != .skip || !includeNone }
    }
}

struct DimensionBadge: View {
    let label: String
    var color: Color = .blue

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(color.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 30, alignment: .leading)

            Text(value)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

#endif
