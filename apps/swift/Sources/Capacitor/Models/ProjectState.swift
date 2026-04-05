import Foundation
import Observation

@Observable
@MainActor
final class ProjectState {
    var projects: [Project] = []
    var suggestedProjects: [SuggestedProject] = []
    var selectedSuggestedPaths: Set<String> = []
    var activeCreations: [ProjectCreation] = []

    private(set) var projectStatuses: [String: ProjectStatus] = [:]

    var manuallyDormant: Set<String> = [] {
        didSet { saveDormantOverrides() }
    }

    var projectOrder: [String] = [] {
        didSet { saveProjectOrder() }
    }

    @ObservationIgnored
    private var previousActivityGroup: [String: ActivityGroup] = [:]

    init() {
        loadDormantOverrides()
        loadProjectOrder()
    }

    func refreshProjectStatuses(using engine: CoreRuntime?) {
        guard let engine else { return }

        var updated: [String: ProjectStatus] = [:]
        for project in projects {
            if let status = try? engine.getProjectStatus(projectPath: project.path) {
                updated[project.path] = status
            }
        }

        if updated != projectStatuses {
            projectStatuses = updated
        }
    }

    func getProjectStatus(for project: Project) -> ProjectStatus? {
        projectStatuses[project.path]
    }

    func prependToProjectOrder(_ path: String) {
        var newOrder = projectOrder
        newOrder.removeAll { $0 == path }
        newOrder.insert(path, at: 0)
        setProjectOrder(
            newOrder,
            reason: "project_added",
            extraPayload: ["path": path],
        )
    }

    func prependToProjectOrder(paths: [String]) {
        let uniqueIncomingPaths = uniquePaths(paths)
        guard !uniqueIncomingPaths.isEmpty else { return }

        var newOrder = projectOrder
        for path in uniqueIncomingPaths {
            newOrder.removeAll { $0 == path }
        }
        newOrder.insert(contentsOf: uniqueIncomingPaths, at: 0)

        setProjectOrder(
            newOrder,
            reason: "projects_added_batch",
            extraPayload: ["pathCount": uniqueIncomingPaths.count],
        )
    }

    func removeProjectOrderEntry(for path: String) {
        var newOrder = projectOrder
        newOrder.removeAll { $0 == path }
        setProjectOrder(
            newOrder,
            reason: "project_removed",
            extraPayload: ["path": path],
        )
    }

    func orderedGroupedProjects(
        _ projects: [Project],
        sessionStates: [String: ProjectSessionState],
        sessionStateRevision: Int,
    ) -> (active: [Project], idle: [Project]) {
        _ = sessionStateRevision
        return ProjectOrdering.orderedGroupedProjects(
            projects,
            order: projectOrder,
            sessionStates: sessionStates,
        )
    }

    func moveProject(
        from source: IndexSet,
        to destination: Int,
        in projectList: [Project],
        group: ActivityGroup,
    ) {
        let visibleProjects = projects.filter { !manuallyDormant.contains($0.path) }
        let newOrder = ProjectOrdering.movedGlobalOrder(
            from: source,
            to: destination,
            in: projectList,
            globalOrder: projectOrder,
            allProjects: visibleProjects,
        )
        setProjectOrder(
            newOrder,
            reason: group == .active ? "drag_reorder_active" : "drag_reorder_idle",
            extraPayload: [
                "groupSize": projectList.count,
                "sourceIndexes": source.map(String.init).joined(separator: ","),
                "destination": destination,
            ],
        )
    }

    func reconcileProjectGroups(sessionStates: [String: ProjectSessionState]) {
        let currentProjectPaths = projects.map(\.path)
        let currentPathSet = Set(currentProjectPaths)
        var transitionCount = 0

        for project in projects {
            let path = project.path
            guard !manuallyDormant.contains(path) else { continue }

            let currentGroup: ActivityGroup = ProjectOrdering.isActive(path, sessionStates: sessionStates) ? .active : .idle
            let previousGroup = previousActivityGroup[path]

            if previousGroup != currentGroup {
                transitionCount += 1
                previousActivityGroup[path] = currentGroup
            }
        }

        let removedPaths = Set(previousActivityGroup.keys).subtracting(currentPathSet)
        for path in removedPaths {
            previousActivityGroup.removeValue(forKey: path)
        }

        var reconciledOrder = uniquePaths(projectOrder).filter { currentPathSet.contains($0) }
        let missingPaths = currentProjectPaths.filter { !reconciledOrder.contains($0) }
        reconciledOrder.append(contentsOf: missingPaths)

        var payload: [String: Any] = [
            "transitionCount": transitionCount,
            "removedPathCount": removedPaths.count,
            "missingPathCount": missingPaths.count,
        ]
        if !missingPaths.isEmpty {
            payload["missingPaths"] = missingPaths
        }
        if !removedPaths.isEmpty {
            payload["removedPaths"] = Array(removedPaths)
        }

        let hadDuplicates = uniquePaths(projectOrder).count != projectOrder.count
        if hadDuplicates {
            emitProjectOrderAnomaly(
                "Deduplicated project order during session reconcile",
                payload: ["reason": "duplicate_paths_detected"],
            )
        }
        if !missingPaths.isEmpty {
            emitProjectOrderAnomaly(
                "Appended missing project paths to persisted order",
                payload: [
                    "reason": "missing_paths",
                    "missingPathCount": missingPaths.count,
                ],
            )
        }

        setProjectOrder(
            reconciledOrder,
            reason: "session_reconcile",
            extraPayload: payload,
        )
    }

    func resetProjectTracking(for path: String) {
        previousActivityGroup.removeValue(forKey: path)
        manuallyDormant.remove(path)
    }

    func moveToDormant(_ project: Project) {
        manuallyDormant.insert(project.path)
    }

    func moveToRecent(_ project: Project) {
        manuallyDormant.remove(project.path)
    }

    func isManuallyDormant(_ project: Project) -> Bool {
        manuallyDormant.contains(project.path)
    }

    private func loadDormantOverrides() {
        manuallyDormant = DormantOverrideStore.load()
    }

    private func saveDormantOverrides() {
        DormantOverrideStore.save(manuallyDormant)
    }

    private func loadProjectOrder() {
        projectOrder = ProjectOrderStore.load()
    }

    private func saveProjectOrder() {
        ProjectOrderStore.save(projectOrder)
    }

    private func setProjectOrder(
        _ newOrder: [String],
        reason: String,
        extraPayload: [String: Any] = [:],
    ) {
        let normalizedOrder = uniquePaths(newOrder)
        let oldOrder = projectOrder
        guard normalizedOrder != oldOrder else { return }

        projectOrder = normalizedOrder

        var payload = extraPayload
        payload["reason"] = reason
        payload["oldCount"] = oldOrder.count
        payload["newCount"] = normalizedOrder.count
        payload["changedPathCount"] = Set(oldOrder).symmetricDifference(Set(normalizedOrder)).count
        Telemetry.emit("project_order_changed", "Project order updated", payload: payload)
    }

    private func emitProjectOrderAnomaly(_ message: String, payload: [String: Any]) {
        Telemetry.emit("project_order_anomaly", message, payload: payload)
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(paths.count)
        for path in paths where !seen.contains(path) {
            seen.insert(path)
            result.append(path)
        }
        return result
    }
}
