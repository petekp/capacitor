import AppKit
import SwiftUI

@MainActor
struct WelcomeView: View {
    var onComplete: () -> Void

    @State private var manager = SetupRequirementsManager()
    @State private var checkID = UUID()
    @State private var isUsingSetupPreviewMode = false

    private var userFirstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    var body: some View {
        PageScaffold {
            SetupDebugScenarioPicker(
                manager: $manager,
                checkID: $checkID,
                isUsingPreviewMode: $isUsingSetupPreviewMode,
            )
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
                            linkURL: step.id == .claude ? URL(string: "https://claude.ai/download") : nil,
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
                if let initializationErrorMessage = manager.initializationErrorMessage {
                    Text(initializationErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

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
            guard !isUsingSetupPreviewMode else { return }
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
        AppDebugSupport.restoreOnboardingBackup()
        onComplete()
    }
}
