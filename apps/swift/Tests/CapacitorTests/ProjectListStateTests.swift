@testable import Capacitor
import XCTest

@MainActor
final class ProjectListStateTests: XCTestCase {
    func testDormantOverridesAndOrderingBelongToProjectListState() {
        let state = ProjectListState(
            projectListPreferencesGateway: StubProjectListPreferencesGateway(
                dormantPaths: ["/tmp/paused"],
                projectOrder: ["/tmp/intent", "/tmp/capacitor", "/tmp/paused"],
            ),
        )
        let capacitor = makeProject(name: "Capacitor", path: "/tmp/capacitor")
        let intent = makeProject(name: "Intent", path: "/tmp/intent")
        let paused = makeProject(name: "Paused", path: "/tmp/paused")

        XCTAssertEqual(
            state.visibleProjects(from: [capacitor, intent, paused]).map(\.path),
            ["/tmp/capacitor", "/tmp/intent"],
        )
        XCTAssertEqual(
            state.pausedProjects(from: [capacitor, intent, paused]).map(\.path),
            ["/tmp/paused"],
        )
        XCTAssertTrue(state.isManuallyDormant(paused))
        XCTAssertEqual(state.projectOrder, ["/tmp/intent", "/tmp/capacitor", "/tmp/paused"])
    }

    func testDormantOverridesAndOrderingSupportShellCatalogEntries() {
        let state = ProjectListState(
            projectListPreferencesGateway: StubProjectListPreferencesGateway(
                dormantPaths: ["/tmp/paused"],
                projectOrder: ["/tmp/intent", "/tmp/capacitor", "/tmp/paused"],
            ),
        )
        let capacitor = ShellProjectCatalogEntry(displayName: "Capacitor", path: "/tmp/capacitor")
        let intent = ShellProjectCatalogEntry(displayName: "Intent", path: "/tmp/intent")
        let paused = ShellProjectCatalogEntry(displayName: "Paused", path: "/tmp/paused")

        XCTAssertEqual(
            state.visibleProjects(from: [capacitor, intent, paused]).map(\.path),
            ["/tmp/capacitor", "/tmp/intent"],
        )
        XCTAssertEqual(
            state.pausedProjects(from: [capacitor, intent, paused]).map(\.path),
            ["/tmp/paused"],
        )
        XCTAssertTrue(state.isManuallyDormant(paused))
    }

    func testMoveProjectUpdatesGlobalOrderAndPersistsIt() {
        let preferences = StubProjectListPreferencesGateway(
            dormantPaths: [],
            projectOrder: ["/tmp/a", "/tmp/b", "/tmp/c"],
        )
        let state = ProjectListState(projectListPreferencesGateway: preferences)
        let projects = [
            makeProject(name: "A", path: "/tmp/a"),
            makeProject(name: "B", path: "/tmp/b"),
            makeProject(name: "C", path: "/tmp/c"),
        ]

        state.moveProject(
            from: IndexSet(integer: 2),
            to: 0,
            in: projects,
            allProjects: projects,
            group: .active,
        )

        XCTAssertEqual(state.projectOrder, ["/tmp/c", "/tmp/a", "/tmp/b"])
        XCTAssertEqual(preferences.savedProjectOrders.last, ["/tmp/c", "/tmp/a", "/tmp/b"])
    }

    func testReconcileProjectGroupsPrunesRemovedProjectsAndAppendsMissingPaths() {
        let preferences = StubProjectListPreferencesGateway(
            dormantPaths: [],
            projectOrder: ["/tmp/missing", "/tmp/capacitor"],
        )
        let state = ProjectListState(projectListPreferencesGateway: preferences)
        let projects = [
            makeProject(name: "Capacitor", path: "/tmp/capacitor"),
            makeProject(name: "Intent", path: "/tmp/intent"),
        ]

        state.reconcileProjectGroups(
            projects: projects,
            sessionStates: [:],
        )

        XCTAssertEqual(state.projectOrder, ["/tmp/capacitor", "/tmp/intent"])
        XCTAssertEqual(preferences.savedProjectOrders.last, ["/tmp/capacitor", "/tmp/intent"])
    }

    func testMovePathToRecentClearsDormantOverrideAndPersists() {
        let preferences = StubProjectListPreferencesGateway(
            dormantPaths: ["/tmp/paused"],
            projectOrder: [],
        )
        let state = ProjectListState(projectListPreferencesGateway: preferences)

        XCTAssertTrue(state.isManuallyDormant(path: "/tmp/paused"))

        state.movePathToRecent("/tmp/paused")

        XCTAssertFalse(state.isManuallyDormant(path: "/tmp/paused"))
        XCTAssertEqual(preferences.savedDormantPaths.last, [])
    }

    private func makeProject(name: String, path: String) -> Project {
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
}

@MainActor
private final class StubProjectListPreferencesGateway: ProjectListPreferencesGateway {
    private let initialDormantPaths: Set<String>
    private let initialProjectOrder: [String]

    private(set) var savedDormantPaths: [Set<String>] = []
    private(set) var savedProjectOrders: [[String]] = []
    private(set) var didMigrateProjectOrder = false

    init(dormantPaths: Set<String>, projectOrder: [String]) {
        initialDormantPaths = dormantPaths
        initialProjectOrder = projectOrder
    }

    func loadDormantProjectPaths() -> Set<String> {
        initialDormantPaths
    }

    func saveDormantProjectPaths(_ paths: Set<String>) {
        savedDormantPaths.append(paths)
    }

    func loadProjectOrder() -> [String] {
        initialProjectOrder
    }

    func saveProjectOrder(_ order: [String]) {
        savedProjectOrders.append(order)
    }
}
