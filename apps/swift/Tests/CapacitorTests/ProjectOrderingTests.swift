@testable import Capacitor
import XCTest

final class ProjectOrderingTests: XCTestCase {
    // MARK: - Test Helpers

    private func makeProject(_ name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private func makeSessionState(_ state: SessionState, stateChangedAt: String? = nil) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: stateChangedAt,
            updatedAt: nil,
            sessionId: nil,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: state != .idle,
        )
    }

    // MARK: - orderedProjects (basic, pre-existing)

    func testOrderedProjectsRespectsCustomOrderAndKeepsRemaining() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")

        let ordered = ProjectOrdering.orderedProjects(
            [projectA, projectB, projectC],
            customOrder: ["/tmp/c", "/tmp/a"],
        )

        XCTAssertEqual(ordered.map(\.path), ["/tmp/c", "/tmp/a", "/tmp/b"])
    }

    func testMovedOrderOnlyUsesProvidedList() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")

        let moved = ProjectOrdering.movedOrder(
            from: IndexSet(integer: 2),
            to: 0,
            in: [projectA, projectB, projectC],
        )

        XCTAssertEqual(moved, ["/tmp/c", "/tmp/a", "/tmp/b"])
    }

    // MARK: - isActive classification

    func testIsActiveReturnsTrueForWorkingSession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
        ]
        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsTrueForWaitingSession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.waiting),
        ]
        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsTrueForCompactingSession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.compacting),
        ]
        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsTrueForReadySession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.ready),
        ]
        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsFalseForIdleSession() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.idle),
        ]
        XCTAssertFalse(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveReturnsTrueForRecentlyIdleSessionWithinGraceWindow() {
        let now = Date()
        let justNow = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(-3))
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.idle, stateChangedAt: justNow),
        ]

        XCTAssertTrue(ProjectOrdering.isActive("/tmp/a", sessionStates: states, now: now))
    }

    func testIsActiveReturnsFalseForIdleSessionOutsideGraceWindow() {
        let now = Date()
        let old = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(-15))
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.idle, stateChangedAt: old),
        ]

        XCTAssertFalse(ProjectOrdering.isActive("/tmp/a", sessionStates: states, now: now))
    }

    func testActivityBandReturnsCoolingForRecentlyIdleSession() {
        let now = Date()
        let recentIdle = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(-2))
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.idle, stateChangedAt: recentIdle),
        ]

        XCTAssertEqual(
            ProjectOrdering.activityBand("/tmp/a", sessionStates: states, now: now),
            .cooling,
        )
    }

    func testIsActiveReturnsFalseForNoSession() {
        let states: [String: ProjectSessionState] = [:]
        XCTAssertFalse(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    func testIsActiveUsesNormalizedPathFallback() {
        let states: [String: ProjectSessionState] = [
            "/tmp/../tmp/a/": makeSessionState(.working),
        ]

        XCTAssertTrue(ProjectOrdering.isActive("/TMP/a", sessionStates: states))
    }

    func testIsActivePrefersDirectLookupOverNormalizedFallback() {
        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.idle),
            "/tmp/../tmp/A/": makeSessionState(.working),
        ]

        XCTAssertFalse(ProjectOrdering.isActive("/tmp/a", sessionStates: states))
    }

    // MARK: - orderedGroupedProjects

    func testGroupedProjectsSplitsActiveAndIdle() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")

        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
            "/tmp/c": makeSessionState(.ready),
        ]

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB, projectC],
            order: ["/tmp/c", "/tmp/a", "/tmp/b"],
            sessionStates: states,
        )

        XCTAssertEqual(result.active.map(\.path), ["/tmp/c", "/tmp/a"])
        XCTAssertEqual(result.idle.map(\.path), ["/tmp/b"])
    }

    func testGroupedProjectsRespectsOrderWithinGroups() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")
        let projectD = makeProject("D", path: "/tmp/d")

        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
            "/tmp/d": makeSessionState(.waiting),
        ]

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB, projectC, projectD],
            order: ["/tmp/d", "/tmp/a", "/tmp/c", "/tmp/b"],
            sessionStates: states,
        )

        // Active: D before A (per global order)
        XCTAssertEqual(result.active.map(\.path), ["/tmp/d", "/tmp/a"])
        // Idle: C before B (per global order)
        XCTAssertEqual(result.idle.map(\.path), ["/tmp/c", "/tmp/b"])
    }

    func testGroupedProjectsKeepsRecentlyIdleProjectInActiveBucketDuringGraceWindow() {
        let now = Date()
        let recentIdle = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(-2))

        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")

        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.idle, stateChangedAt: recentIdle),
            "/tmp/b": makeSessionState(.working),
        ]

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB, projectC],
            order: ["/tmp/a", "/tmp/b", "/tmp/c"],
            sessionStates: states,
        )

        XCTAssertEqual(result.active.map(\.path), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(result.idle.map(\.path), ["/tmp/c"])
    }

    func testGroupedProjectsAllIdle() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB],
            order: ["/tmp/b", "/tmp/a"],
            sessionStates: [:],
        )

        XCTAssertTrue(result.active.isEmpty)
        XCTAssertEqual(result.idle.map(\.path), ["/tmp/b", "/tmp/a"])
    }

    func testGroupedProjectsAllActive() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")

        let states: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
            "/tmp/b": makeSessionState(.ready),
        ]

        let result = ProjectOrdering.orderedGroupedProjects(
            [projectA, projectB],
            order: ["/tmp/a", "/tmp/b"],
            sessionStates: states,
        )

        XCTAssertEqual(result.active.map(\.path), ["/tmp/a", "/tmp/b"])
        XCTAssertTrue(result.idle.isEmpty)
    }

    // MARK: - Global order model

    func testGroupedProjectsUsesSingleGlobalOrderAcrossActivityTransitions() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")
        let all = [projectA, projectB, projectC]
        let order = ["/tmp/b", "/tmp/a", "/tmp/c"]

        let initialStates: [String: ProjectSessionState] = [
            "/tmp/b": makeSessionState(.working),
            "/tmp/c": makeSessionState(.ready),
            "/tmp/a": makeSessionState(.idle),
        ]
        let initial = ProjectOrdering.orderedGroupedProjects(
            all,
            order: order,
            sessionStates: initialStates,
        )
        XCTAssertEqual(initial.active.map(\.path), ["/tmp/b", "/tmp/c"])
        XCTAssertEqual(initial.idle.map(\.path), ["/tmp/a"])

        let transitionedStates: [String: ProjectSessionState] = [
            "/tmp/a": makeSessionState(.working),
            "/tmp/c": makeSessionState(.ready),
            "/tmp/b": makeSessionState(.idle),
        ]
        let transitioned = ProjectOrdering.orderedGroupedProjects(
            all,
            order: order,
            sessionStates: transitionedStates,
            now: Date().addingTimeInterval(20),
        )
        XCTAssertEqual(transitioned.active.map(\.path), ["/tmp/a", "/tmp/c"])
        XCTAssertEqual(transitioned.idle.map(\.path), ["/tmp/b"])
    }

    func testMoveWithinGroupUpdatesGlobalOrderWithoutPerturbingOtherGroup() {
        let projectA = makeProject("A", path: "/tmp/a")
        let projectB = makeProject("B", path: "/tmp/b")
        let projectC = makeProject("C", path: "/tmp/c")
        let projectD = makeProject("D", path: "/tmp/d")

        let globalOrder = ["/tmp/a", "/tmp/b", "/tmp/c", "/tmp/d"]
        let activeGroup = [projectA, projectC]
        let allProjects = [projectA, projectB, projectC, projectD]

        let moved = ProjectOrdering.movedGlobalOrder(
            from: IndexSet(integer: 1),
            to: 0,
            in: activeGroup,
            globalOrder: globalOrder,
            allProjects: allProjects,
        )

        XCTAssertEqual(moved, ["/tmp/c", "/tmp/b", "/tmp/a", "/tmp/d"])
    }

    // MARK: - Migration

    func testMigrateIfNeededCopiesLegacyOrderToGlobal() throws {
        let suiteName = "test-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(["/tmp/a", "/tmp/b", "/tmp/c"], forKey: "customProjectOrder")

        ProjectOrderStore.migrateIfNeeded(from: defaults)

        let globalOrder = defaults.array(forKey: "projectOrder.global") as? [String] ?? []
        let migrated = defaults.bool(forKey: "projectOrder.migrated.v3")

        XCTAssertEqual(globalOrder, ["/tmp/a", "/tmp/b", "/tmp/c"])
        XCTAssertTrue(migrated)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMigrateIfNeededDoesNotRunTwice() throws {
        let suiteName = "test-migration-idempotent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(["/tmp/a"], forKey: "customProjectOrder")

        ProjectOrderStore.migrateIfNeeded(from: defaults)

        // Change global order after migration
        defaults.set(["/tmp/z"], forKey: "projectOrder.global")

        // Run migration again — should be no-op
        ProjectOrderStore.migrateIfNeeded(from: defaults)

        let globalOrder = defaults.array(forKey: "projectOrder.global") as? [String] ?? []
        XCTAssertEqual(globalOrder, ["/tmp/z"], "Migration should not overwrite after first run")

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMigrateIfNeededHandlesEmptyLegacy() throws {
        let suiteName = "test-migration-empty-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // No legacy key set

        ProjectOrderStore.migrateIfNeeded(from: defaults)

        let globalOrder = defaults.array(forKey: "projectOrder.global") as? [String]
        let migrated = defaults.bool(forKey: "projectOrder.migrated.v3")

        // No global order set (legacy was empty), but migration flag should be set
        XCTAssertNil(globalOrder)
        XCTAssertTrue(migrated)

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Store load/save

    func testStoreLoadAndSaveGlobalOrder() throws {
        let suiteName = "test-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        ProjectOrderStore.save(["/tmp/a", "/tmp/b", "/tmp/c"], to: defaults)

        XCTAssertEqual(ProjectOrderStore.load(from: defaults), ["/tmp/a", "/tmp/b", "/tmp/c"])

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Card identity

    func testCardIdentityKeyRemainsStableAcrossSessionStateTransitions() {
        let workingKey = ProjectOrdering.cardIdentityKey(
            projectPath: "/tmp/a",
            sessionState: makeSessionState(.working),
        )
        let readyKey = ProjectOrdering.cardIdentityKey(
            projectPath: "/tmp/a",
            sessionState: makeSessionState(.ready),
        )

        XCTAssertEqual(
            workingKey,
            readyKey,
            "Card container identity must stay stable across daemon state changes to prevent remount fade/scale artifacts.",
        )
    }

    func testCardContentStateFingerprintChangesAcrossSessionStateTransitions() {
        let workingFingerprint = ProjectOrdering.cardContentStateFingerprint(
            sessionState: makeSessionState(.working),
        )
        let readyFingerprint = ProjectOrdering.cardContentStateFingerprint(
            sessionState: makeSessionState(.ready),
        )

        XCTAssertNotEqual(
            workingFingerprint,
            readyFingerprint,
            "Card content fingerprint should change across daemon states so inner card content refreshes without remounting the outer row.",
        )
    }
}
