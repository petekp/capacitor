/// Distinguishes "genuinely zero connected projects" (show first-run onboarding)
/// from "a project load failed" (show a recoverable error), so a transient
/// loadDashboard() failure never masquerades as first-run onboarding.
enum ProjectsEmptyStatePolicy {
    static func shouldShowConnectOnboarding(
        isLoading: Bool,
        projectsAreEmpty: Bool,
        loadPhase: ProjectsLoadPhase,
    ) -> Bool {
        !isLoading && projectsAreEmpty && loadPhase == .loaded
    }

    static func shouldShowLoadFailure(
        isLoading: Bool,
        projectsAreEmpty: Bool,
        loadPhase: ProjectsLoadPhase,
    ) -> Bool {
        !isLoading && projectsAreEmpty && loadPhase == .failed
    }
}
