import SwiftUI
import AppKit

struct WelcomeView: View {
    @State private var manager = SetupRequirementsManager()
    @State private var checkID = UUID()
    var onComplete: () -> Void

    private var logomarkImage: NSImage? {
        guard let url = Bundle.module.url(forResource: "logomark", withExtension: "pdf") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var userFirstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 40)

                headerSection
                    .padding(.bottom, 32)

                stepsSection

                Spacer()
                    .frame(minHeight: 40)

                footerSection
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: checkID) {
            await manager.runChecks()
        }
        .onAppear {
            manager = SetupRequirementsManager()
            checkID = UUID()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            Group {
                if let nsImage = logomarkImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text("Hi \(userFirstName)! Let's get you all set up.")
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Steps

    private var stepsSection: some View {
        VStack(spacing: 10) {
            ForEach(Array(manager.steps.enumerated()), id: \.element.id) { index, step in
                SetupStepRow(
                    step: step,
                    isCurrentStep: manager.currentStepIndex == index,
                    onAction: {
                        _Concurrency.Task {
                            await manager.executeStep(step.id)
                        }
                    },
                    onRetry: {
                        _Concurrency.Task {
                            await manager.retryStep(step.id)
                        }
                    }
                )
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
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
        .padding(.top, 24)
    }

    // MARK: - Actions

    private func completeSetup() {
        _Concurrency.Task {
            await CapacitorConfig.shared.markSetupComplete()
            onComplete()
        }
    }
}

#Preview("All Complete") {
    WelcomeView(onComplete: { print("Complete!") })
        .preferredColorScheme(.dark)
}

#Preview("In Progress") {
    WelcomeView(onComplete: { print("Complete!") })
        .preferredColorScheme(.dark)
}
