@testable import Capacitor
import XCTest

final class HookInstallerTests: XCTestCase {
    func testEnsureHooksInstalledStopsWhenBinaryInstallFails() {
        let runtime = StubHookRuntime(
            installHooksResult: .success(InstallResult(success: true, message: "ok", scriptPath: nil)),
            hookStatus: .installed(version: "1.0.0"),
        )

        let message = HookInstaller.ensureHooksInstalled(
            using: runtime,
            binaryInstallStep: { _ in "missing bundled binary" },
        )

        XCTAssertEqual(message, "missing bundled binary")
        XCTAssertEqual(runtime.installHooksCallCount, 0)
    }

    func testEnsureHooksInstalledReturnsInstallHooksFailureMessage() {
        let runtime = StubHookRuntime(
            installHooksResult: .success(InstallResult(success: false, message: "config write failed", scriptPath: nil)),
            hookStatus: .notInstalled,
        )

        let message = HookInstaller.ensureHooksInstalled(
            using: runtime,
            binaryInstallStep: { _ in nil },
        )

        XCTAssertEqual(message, "config write failed")
        XCTAssertEqual(runtime.installHooksCallCount, 1)
    }

    func testEnsureHooksInstalledReturnsThrownInstallError() {
        let runtime = StubHookRuntime(
            installHooksResult: .failure(StubError("boom")),
            hookStatus: .notInstalled,
        )

        let message = HookInstaller.ensureHooksInstalled(
            using: runtime,
            binaryInstallStep: { _ in nil },
        )

        XCTAssertEqual(message, "Installation failed: boom")
        XCTAssertEqual(runtime.installHooksCallCount, 1)
    }

    func testEnsureHooksInstalledRequiresInstalledStatusAfterSuccess() {
        let runtime = StubHookRuntime(
            installHooksResult: .success(InstallResult(success: true, message: "configured", scriptPath: nil)),
            hookStatus: .policyBlocked(reason: "managed hooks disabled"),
        )

        let message = HookInstaller.ensureHooksInstalled(
            using: runtime,
            binaryInstallStep: { _ in nil },
        )

        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("policyBlocked") == true)
    }

    func testEnsureHooksInstalledReturnsNilOnSuccess() {
        let runtime = StubHookRuntime(
            installHooksResult: .success(InstallResult(success: true, message: "configured", scriptPath: nil)),
            hookStatus: .installed(version: "1.0.0"),
        )

        let message = HookInstaller.ensureHooksInstalled(
            using: runtime,
            binaryInstallStep: { _ in nil },
        )

        XCTAssertNil(message)
        XCTAssertEqual(runtime.installHooksCallCount, 1)
    }

    func testPreferredLaunchBinaryPathUsesCanonicalInstallInDevelopment() {
        let path = HookBinaryLocator.preferredLaunchBinaryPath(
            isRunningFromAppBundle: false,
            installedBinaryPath: "/tmp/.local/bin/hud-hook",
            bundledBinaryPath: "/tmp/Capacitor.app/Contents/Resources/hud-hook",
            isExecutableFile: { _ in true },
        )

        XCTAssertEqual(path, "/tmp/.local/bin/hud-hook")
    }

    func testPreferredLaunchBinaryPathUsesBundledBinaryInDistributedApp() {
        let path = HookBinaryLocator.preferredLaunchBinaryPath(
            isRunningFromAppBundle: true,
            installedBinaryPath: "/tmp/.local/bin/hud-hook",
            bundledBinaryPath: "/tmp/Capacitor.app/Contents/Resources/hud-hook",
            isExecutableFile: { _ in true },
        )

        XCTAssertEqual(path, "/tmp/Capacitor.app/Contents/Resources/hud-hook")
    }

    func testInstallSourceBinaryPathSkipsBundledCopyInDevelopment() {
        let sourcePath = HookBinaryLocator.installSourceBinaryPath(
            isRunningFromAppBundle: false,
            installedBinaryPath: "/tmp/.local/bin/hud-hook",
            bundledBinaryPath: "/tmp/Capacitor.app/Contents/Resources/hud-hook",
            isExecutableFile: { path in
                path == "/tmp/Capacitor.app/Contents/Resources/hud-hook"
            },
        )

        XCTAssertNil(sourcePath)
    }
}

private struct StubError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private final class StubHookRuntime: HookRuntimeInstalling {
    let installHooksResult: Result<InstallResult, Error>
    let hookStatus: HookStatus
    var installHooksCallCount = 0

    init(
        installHooksResult: Result<InstallResult, Error>,
        hookStatus: HookStatus,
    ) {
        self.installHooksResult = installHooksResult
        self.hookStatus = hookStatus
    }

    func installHookBinaryFromPath(sourcePath _: String) throws -> InstallResult {
        InstallResult(success: true, message: "binary ok", scriptPath: nil)
    }

    func installHooks() throws -> InstallResult {
        installHooksCallCount += 1
        return try installHooksResult.get()
    }

    func getHookStatus() -> HookStatus {
        hookStatus
    }
}
