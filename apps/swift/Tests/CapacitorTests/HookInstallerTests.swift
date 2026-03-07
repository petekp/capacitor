@testable import Capacitor
import XCTest

final class HookInstallerTests: XCTestCase {
    func testEnsureHooksInstalledStopsWhenBinaryInstallFails() {
        let runtime = StubHookRuntime(
            installHooksResult: .success(InstallResult(success: true, message: "ok", scriptPath: nil)),
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
        )

        let message = HookInstaller.ensureHooksInstalled(
            using: runtime,
            binaryInstallStep: { _ in nil },
        )

        XCTAssertEqual(message, "Installation failed: boom")
        XCTAssertEqual(runtime.installHooksCallCount, 1)
    }

    func testEnsureHooksInstalledReturnsNilOnSuccess() {
        let runtime = StubHookRuntime(
            installHooksResult: .success(InstallResult(success: true, message: "configured", scriptPath: nil)),
        )

        let message = HookInstaller.ensureHooksInstalled(
            using: runtime,
            binaryInstallStep: { _ in nil },
        )

        XCTAssertNil(message)
        XCTAssertEqual(runtime.installHooksCallCount, 1)
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
    var installHooksCallCount = 0

    init(
        installHooksResult: Result<InstallResult, Error>,
    ) {
        self.installHooksResult = installHooksResult
    }

    func installHookBinaryFromPath(sourcePath _: String) throws -> InstallResult {
        InstallResult(success: true, message: "binary ok", scriptPath: nil)
    }

    func installHooks() throws -> InstallResult {
        installHooksCallCount += 1
        return try installHooksResult.get()
    }
}
