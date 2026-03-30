@testable import Capacitor
import XCTest

final class StartupSetupValidatorTests: XCTestCase {
    func testRepairFailureStillCompletesStartupAndPersistsMarker() {
        let runtime = StubStartupSetupRuntime(
            setupStatus: SetupTestFixtures.setupStatus(
                dependencies: [SetupTestFixtures.claudeDependency(found: true)],
                hooks: .settingsUnreadable(reason: "Failed to parse settings.json"),
            ),
            capacitorDir: "/tmp/capacitor-startup",
        )
        var setupComplete = false
        var recordedEvents: [DebugLog.StartupEvent] = []
        var persistedMarkerRoots: [String] = []
        var shellIntegrationCallCount = 0
        var repairAttemptCount = 0

        StartupSetupValidator.validate(
            using: StartupSetupValidationHooks(
                shouldSkipSetupValidation: { false },
                makeRuntime: { runtime },
                startupDecision: { SetupReadinessCoordinator.startupDecision(from: $0) },
                writeStartupLog: { recordedEvents.append($0) },
                setSetupComplete: { setupComplete = $0 },
                isSetupComplete: { setupComplete },
                attemptAutoRepair: { engine in
                    repairAttemptCount += 1
                    XCTAssertTrue(engine === runtime)
                    recordedEvents.append(.hooksAutoRepairFailed(error: "settings parse failed"))
                    return false
                },
                installShellIntegrationIfNeeded: {
                    shellIntegrationCallCount += 1
                },
                persistSetupMarker: { persistedMarkerRoots.append($0) },
            ),
        )

        XCTAssertEqual(repairAttemptCount, 1)
        XCTAssertEqual(shellIntegrationCallCount, 1)
        XCTAssertEqual(persistedMarkerRoots, ["/tmp/capacitor-startup"])
        XCTAssertTrue(setupComplete)
        XCTAssertEqual(
            recordedEvents,
            [
                .hooksNeedAutoRepair(status: .settingsUnreadable(reason: "Failed to parse settings.json")),
                .hooksAutoRepairFailed(error: "settings parse failed"),
                .autoSetupComplete,
            ],
        )
    }
}

private final class StubStartupSetupRuntime: StartupSetupRuntime {
    let setupStatus: SetupStatus
    let runtimeCapacitorDir: String

    init(setupStatus: SetupStatus, capacitorDir: String) {
        self.setupStatus = setupStatus
        runtimeCapacitorDir = capacitorDir
    }

    func checkSetupStatus() -> SetupStatus {
        setupStatus
    }

    func capacitorDir() -> String {
        runtimeCapacitorDir
    }

    func installHookBinaryFromPath(sourcePath _: String) throws -> InstallResult {
        InstallResult(success: true, message: "binary ok", scriptPath: nil)
    }

    func installHooks() throws -> InstallResult {
        InstallResult(success: false, message: "settings parse failed", scriptPath: nil)
    }

    func getHookStatus() -> HookStatus {
        setupStatus.hooks
    }
}
