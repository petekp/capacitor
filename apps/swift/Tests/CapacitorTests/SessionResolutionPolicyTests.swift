@testable import Capacitor
import XCTest

final class SessionResolutionPolicyTests: XCTestCase {
    func testChooseSessionNamePrefersRoutedSession() async {
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/capacitor",
            routedSessionName: "capacitor",
        )

        XCTAssertEqual(resolved, "capacitor")
    }

    func testChooseSessionNamePrefersInjectedFallbackOverTmuxDiscovery() async {
        let policy = SessionResolutionPolicy(
            discoverFallbackSession: { _ in "fallback-session" },
        )

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/capacitor",
            routedSessionName: nil,
        )

        XCTAssertEqual(resolved, "fallback-session")
    }

    func testChooseSessionNameFallsBackToProjectSlugWhenNoStrongerSignalExists() async {
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/capacitor",
            routedSessionName: nil,
        )

        XCTAssertEqual(resolved, "capacitor")
    }

    // MARK: - Cross-Project Session Name Validation

    func testAcceptsRoutedSessionNameRegardlessOfProjectMatch() async {
        // The runtime router resolved that this session is associated with the
        // project based on live shell/CWD data. Trust that resolution even when
        // the session name doesn't resemble the project slug.
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/circuit",
            routedSessionName: "arc-design-studio",
        )

        XCTAssertEqual(resolved, "arc-design-studio",
                       "Runtime-routed session names should be trusted")
    }

    func testAcceptsSameProjectSessionName() async {
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/circuit",
            routedSessionName: "circuit",
        )

        XCTAssertEqual(resolved, "circuit")
    }

    func testAcceptsGenericSessionName() async {
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/circuit",
            routedSessionName: "dev",
        )

        XCTAssertEqual(resolved, "dev",
                       "Generic session names like 'dev' should be accepted for any project")
    }

    func testAcceptsSessionNameThatIsSubstringOfProjectSlug() async {
        // Session name "capac" is a literal substring of "capacitor",
        // so the slug contains the session name.
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/capacitor",
            routedSessionName: "capac",
        )

        XCTAssertEqual(resolved, "capac")
    }

    func testAcceptsSessionNameContainingProjectSlug() async {
        // Session "capacitor-work" contains the project slug "capacitor".
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/capacitor",
            routedSessionName: "capacitor-work",
        )

        XCTAssertEqual(resolved, "capacitor-work")
    }

    func testRoutedNameTakesPrecedenceOverFallbackDiscovery() async {
        // When a routed name exists, it takes precedence even if a
        // fallback discovery is configured.
        let policy = SessionResolutionPolicy(
            discoverFallbackSession: { _ in "discovered-circuit" },
        )

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/circuit",
            routedSessionName: "arc-design-studio",
        )

        XCTAssertEqual(resolved, "arc-design-studio",
                       "Routed name should take precedence over fallback discovery")
    }

    func testAcceptsArbitrarySessionNamesWhenRouted() async {
        let policy = SessionResolutionPolicy()

        // These are legitimate tmux session names that don't match any project slug
        for name in ["hud", "pkp", "feature-x", "my-workspace", "coding-2024"] {
            let resolved = await policy.chooseSessionName(
                projectPath: "/Users/pete/Code/capacitor",
                routedSessionName: name,
            )
            XCTAssertEqual(resolved, name,
                           "Arbitrary routed session name '\(name)' should be accepted")
        }
    }

    func testGenericNamesAreCaseInsensitive() async {
        let policy = SessionResolutionPolicy()

        let resolved = await policy.chooseSessionName(
            projectPath: "/Users/pete/Code/circuit",
            routedSessionName: "Main",
        )

        XCTAssertEqual(resolved, "Main",
                       "Generic session name matching should be case-insensitive")
    }

    // MARK: - Direct Validation Method

    func testSessionNameBelongsToProject() {
        let policy = SessionResolutionPolicy()

        // Same name
        XCTAssertTrue(policy.sessionNameBelongsToProject(
            sessionName: "circuit", projectPath: "/Code/circuit",
        ))

        // Generic
        XCTAssertTrue(policy.sessionNameBelongsToProject(
            sessionName: "main", projectPath: "/Code/circuit",
        ))

        // Session contains slug
        XCTAssertTrue(policy.sessionNameBelongsToProject(
            sessionName: "circuit-dev", projectPath: "/Code/circuit",
        ))

        // Slug contains session
        XCTAssertTrue(policy.sessionNameBelongsToProject(
            sessionName: "cap", projectPath: "/Code/capacitor",
        ))

        // Unrelated
        XCTAssertFalse(policy.sessionNameBelongsToProject(
            sessionName: "arc-design-studio", projectPath: "/Code/circuit",
        ))

        // Case insensitive
        XCTAssertTrue(policy.sessionNameBelongsToProject(
            sessionName: "Circuit", projectPath: "/Code/circuit",
        ))
    }

    // MARK: - Short Slug Reverse Containment

    func testRejectsSingleCharSessionNameForReverseContainment() {
        let policy = SessionResolutionPolicy()
        // "a" is contained in "capacitor" but should be rejected (too short for reverse match)
        XCTAssertFalse(policy.sessionNameBelongsToProject(
            sessionName: "a",
            projectPath: "/Code/capacitor",
        ))
    }

    func testRejectsTwoCharSessionNameForReverseContainment() {
        let policy = SessionResolutionPolicy()
        // "go" is contained in "golang" but should be rejected (too short for reverse match)
        XCTAssertFalse(policy.sessionNameBelongsToProject(
            sessionName: "go",
            projectPath: "/Code/golang",
        ))
    }

    func testAcceptsTwoCharSessionNameWhenExactMatch() {
        let policy = SessionResolutionPolicy()
        // "go" contains "go" via forward containment (exact match), so this should pass
        XCTAssertTrue(policy.sessionNameBelongsToProject(
            sessionName: "go",
            projectPath: "/Code/go",
        ))
    }

    func testAcceptsThreeCharSessionNameForReverseContainment() {
        let policy = SessionResolutionPolicy()
        // "cap" is >= 3 chars and is contained in "capacitor", so reverse match succeeds
        XCTAssertTrue(policy.sessionNameBelongsToProject(
            sessionName: "cap",
            projectPath: "/Code/capacitor",
        ))
    }
}
