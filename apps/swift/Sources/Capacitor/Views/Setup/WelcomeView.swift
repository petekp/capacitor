import AppKit
import SwiftUI

@MainActor
struct WelcomeView: View {
    var onComplete: () -> Void

    @State private var manager = SetupRequirementsManager()
    @State private var checkID = UUID()

    #if DEBUG
        @State private var debugScenario: SetupPreviewScenario?
    #endif

    private var userFirstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    var body: some View {
        PageScaffold {
            // MARK: - Fixed header (debug picker only)

            #if DEBUG
                debugScenarioPicker
            #else
                EmptyView()
            #endif
        } content: {
            // MARK: - Scrollable content: logo, greeting, then steps

            VStack(spacing: OnboardingStyle.headerToContentSpacing) {
                VStack(spacing: OnboardingStyle.logoToHeadingSpacing) {
                    BrandLogomark(size: OnboardingStyle.logomarkSize)

                    VStack(spacing: 4) {
                        Text("Hi \(userFirstName)!")
                            .font(AppTypography.onboardingHeading)
                            .foregroundStyle(OnboardingStyle.headingColor)

                        Text("Let's make sure you're all set up.")
                            .font(AppTypography.onboardingSubtitle)
                            .foregroundStyle(OnboardingStyle.subtitleColor)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

                VStack(spacing: 10) {
                    ForEach(Array(manager.steps.enumerated()), id: \.element.id) { index, step in
                        SetupStepRow(
                            step: step,
                            isCurrentStep: manager.currentStepIndex == index,
                            linkURL: step.id == "claude" ? URL(string: "https://claude.ai/download") : nil,
                            onAction: {
                                _Concurrency.Task {
                                    await manager.executeStep(step.id)
                                }
                            },
                            onRetry: {
                                _Concurrency.Task {
                                    await manager.retryStep(step.id)
                                }
                            },
                        )
                    }
                }
            }
        } footer: {
            // MARK: - Fixed footer

            VStack(spacing: 16) {
                if manager.hasBlockingError {
                    Text("Please resolve the issues above to continue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: completeSetup) {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!manager.allComplete)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: checkID) {
            await manager.runChecks()
        }
        .onAppear {
            #if DEBUG
                guard debugScenario == nil else { return }
            #endif
            manager = SetupRequirementsManager()
            checkID = UUID()
        }
        .sheet(isPresented: $manager.showShellInstructions) {
            ShellInstructionsSheet(
                isPresented: $manager.showShellInstructions,
                onDismiss: { manager.dismissShellInstructions() },
            )
        }
    }

    // MARK: - Actions

    private func completeSetup() {
        _Concurrency.Task {
            await CapacitorConfig.shared.markSetupComplete()

            #if DEBUG
                CapacitorApp.restoreOnboardingBackup()
            #endif

            onComplete()
        }
    }
}

// MARK: - Debug Scenario Picker

#if DEBUG
    extension WelcomeView {
        private var debugScenarioPicker: some View {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "ant.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))

                    Text("Setup State")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    Picker("", selection: $debugScenario) {
                        Text("Live").tag(SetupPreviewScenario?.none)
                        Divider()
                        ForEach(SetupPreviewScenario.allCases) { scenario in
                            Text(scenario.rawValue).tag(Optional(scenario))
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.mini)
                    .frame(width: 140)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.top, 8)
            .onChange(of: debugScenario) { _, newValue in
                if let scenario = newValue {
                    manager = .preview(scenario)
                } else {
                    manager = SetupRequirementsManager()
                    checkID = UUID()
                }
            }
        }
    }
#endif
