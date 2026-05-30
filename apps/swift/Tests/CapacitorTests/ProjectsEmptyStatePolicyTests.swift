@testable import Capacitor
import XCTest

final class ProjectsEmptyStatePolicyTests: XCTestCase {
    func testConnectOnboardingOnlyShowsAfterLoadedEmptyProjects() {
        XCTAssertFalse(
            ProjectsEmptyStatePolicy.shouldShowConnectOnboarding(
                isLoading: false,
                projectsAreEmpty: true,
                loadPhase: .failed,
            ),
        )
        XCTAssertTrue(
            ProjectsEmptyStatePolicy.shouldShowConnectOnboarding(
                isLoading: false,
                projectsAreEmpty: true,
                loadPhase: .loaded,
            ),
        )
        XCTAssertFalse(
            ProjectsEmptyStatePolicy.shouldShowConnectOnboarding(
                isLoading: true,
                projectsAreEmpty: true,
                loadPhase: .loaded,
            ),
        )
        XCTAssertFalse(
            ProjectsEmptyStatePolicy.shouldShowConnectOnboarding(
                isLoading: false,
                projectsAreEmpty: false,
                loadPhase: .loaded,
            ),
        )
    }

    func testLoadFailureShowsOnlyAfterFailedEmptyProjects() {
        XCTAssertTrue(
            ProjectsEmptyStatePolicy.shouldShowLoadFailure(
                isLoading: false,
                projectsAreEmpty: true,
                loadPhase: .failed,
            ),
        )
    }

    func testConnectOnboardingAndLoadFailureAreMutuallyExclusive() {
        for isLoading in [false, true] {
            for projectsAreEmpty in [false, true] {
                for loadPhase in [ProjectsLoadPhase.initial, .loaded, .failed] {
                    let showOnboarding = ProjectsEmptyStatePolicy.shouldShowConnectOnboarding(
                        isLoading: isLoading,
                        projectsAreEmpty: projectsAreEmpty,
                        loadPhase: loadPhase,
                    )
                    let showFailure = ProjectsEmptyStatePolicy.shouldShowLoadFailure(
                        isLoading: isLoading,
                        projectsAreEmpty: projectsAreEmpty,
                        loadPhase: loadPhase,
                    )

                    XCTAssertFalse(
                        showOnboarding && showFailure,
                        "onboarding and failure both true for isLoading=\(isLoading), projectsAreEmpty=\(projectsAreEmpty), loadPhase=\(loadPhase)",
                    )
                }
            }
        }
    }
}
