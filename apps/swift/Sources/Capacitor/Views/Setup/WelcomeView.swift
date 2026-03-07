import AppKit
import SwiftUI

@MainActor
struct WelcomeView: View {
    @Bindable var setupWorkflowState: SetupWorkflowState
    var onComplete: () -> Void

    private var userFirstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    var body: some View {
        PageScaffold {
            SetupDebugScenarioPicker(setupWorkflowState: setupWorkflowState)
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
                    ForEach(Array(setupWorkflowState.steps.enumerated()), id: \.element.id) { index, step in
                        SetupStepRow(
                            step: step,
                            isCurrentStep: setupWorkflowState.currentStepIndex == index,
                            linkURL: step.id == .claude ? URL(string: "https://claude.ai/download") : nil,
                            onAction: {
                                _Concurrency.Task {
                                    await setupWorkflowState.executeStep(step.id)
                                }
                            },
                            onRetry: {
                                _Concurrency.Task {
                                    await setupWorkflowState.retryStep(step.id)
                                }
                            },
                        )
                    }
                }
            }
        } footer: {
            // MARK: - Fixed footer

            VStack(spacing: 16) {
                if let initializationErrorMessage = setupWorkflowState.initializationErrorMessage {
                    Text(initializationErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if setupWorkflowState.hasBlockingError {
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
                .disabled(!setupWorkflowState.allComplete)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: setupWorkflowState.checkID) {
            await setupWorkflowState.runChecks()
        }
        .onAppear {
            guard !setupWorkflowState.isUsingPreviewMode else { return }
            setupWorkflowState.restoreLive()
        }
        .sheet(isPresented: $setupWorkflowState.showShellInstructions) {
            ShellInstructionsSheet(
                isPresented: $setupWorkflowState.showShellInstructions,
                onDismiss: { setupWorkflowState.dismissShellInstructions() },
            )
        }
    }

    // MARK: - Actions

    private func completeSetup() {
        AppDebugSupport.restoreOnboardingBackup()
        onComplete()
    }
}
