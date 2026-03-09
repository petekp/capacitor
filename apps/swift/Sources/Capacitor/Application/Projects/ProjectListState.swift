import Foundation
import Observation

@Observable
@MainActor
final class ProjectListState {
    @ObservationIgnored
    private let projectListPreferencesGateway: any ProjectListPreferencesGateway

    private(set) var manuallyDormant: Set<String>
    private(set) var projectOrder: [String]
    @ObservationIgnored
    private var previousActivityGroup: [String: ActivityGroup] = [:]

    init(projectListPreferencesGateway: any ProjectListPreferencesGateway) {
        self.projectListPreferencesGateway = projectListPreferencesGateway
        manuallyDormant = projectListPreferencesGateway.loadDormantProjectPaths()
        projectOrder = projectListPreferencesGateway.loadProjectOrder()
    }

    func replaceManuallyDormant(with paths: Set<String>) {
        setManuallyDormant(paths)
    }

    func replaceProjectOrder(with order: [String], reason: String = "project_list_state_replaced") {
        setProjectOrder(order, reason: reason)
    }

    func visibleProjects<ProjectType: ProjectPathProviding>(from projects: [ProjectType]) -> [ProjectType] {
        projects.filter { !manuallyDormant.contains($0.path) }
    }

    func pausedProjects<ProjectType: ProjectPathProviding>(from projects: [ProjectType]) -> [ProjectType] {
        let paused = projects.filter { manuallyDormant.contains($0.path) }
        return ProjectOrdering.orderedProjects(paused, customOrder: projectOrder)
    }

    func orderedGroupedProjects<ProjectType: ProjectPathProviding>(
        _ projects: [ProjectType],
        sessionStates: [String: ProjectSessionState],
    ) -> (active: [ProjectType], idle: [ProjectType]) {
        ProjectOrdering.orderedGroupedProjects(
            projects,
            order: projectOrder,
            sessionStates: sessionStates,
        )
    }

    func orderedProjects<ProjectType: ProjectPathProviding>(
        _ projects: [ProjectType],
        sessionStates: [String: ProjectSessionState],
    ) -> [ProjectType] {
        let grouped = orderedGroupedProjects(projects, sessionStates: sessionStates)
        return grouped.active + grouped.idle
    }

    func moveProject<ProjectType: ProjectPathProviding>(
        from source: IndexSet,
        to destination: Int,
        in projectList: [ProjectType],
        allProjects: [ProjectType],
        group: ActivityGroup,
    ) {
        let newOrder = ProjectOrdering.movedGlobalOrder(
            from: source,
            to: destination,
            in: projectList,
            globalOrder: projectOrder,
            allProjects: visibleProjects(from: allProjects),
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

    func prependProject(path: String) {
        prependProjects(paths: [path])
    }

    func prependProjects(paths: [String]) {
        let uniqueIncomingPaths = uniquePaths(paths)
        guard !uniqueIncomingPaths.isEmpty else { return }

        var newOrder = projectOrder
        for path in uniqueIncomingPaths {
            newOrder.removeAll { $0 == path }
        }
        newOrder.insert(contentsOf: uniqueIncomingPaths, at: 0)

        setProjectOrder(
            newOrder,
            reason: uniqueIncomingPaths.count == 1 ? "project_added" : "projects_added_batch",
            extraPayload: uniqueIncomingPaths.count == 1
                ? ["path": uniqueIncomingPaths[0]]
                : [
                    "pathCount": uniqueIncomingPaths.count,
                    "paths": uniqueIncomingPaths,
                ],
        )
    }

    func reconcileProjectGroups(
        projects: [some ProjectPathProviding],
        sessionStates: [String: ProjectSessionState],
    ) {
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

    func removeProject(path: String) {
        var newOrder = projectOrder
        newOrder.removeAll { $0 == path }
        setProjectOrder(
            newOrder,
            reason: "project_removed",
            extraPayload: ["path": path],
        )
        previousActivityGroup.removeValue(forKey: path)
        if manuallyDormant.contains(path) {
            var newDormant = manuallyDormant
            newDormant.remove(path)
            setManuallyDormant(newDormant)
        }
    }

    func moveToDormant(_ project: some ProjectPathProviding) {
        movePathToDormant(project.path)
    }

    func moveToRecent(_ project: some ProjectPathProviding) {
        movePathToRecent(project.path)
    }

    func movePathToDormant(_ path: String) {
        var newDormant = manuallyDormant
        newDormant.insert(path)
        setManuallyDormant(newDormant)
    }

    func movePathToRecent(_ path: String) {
        var newDormant = manuallyDormant
        newDormant.remove(path)
        setManuallyDormant(newDormant)
    }

    func isManuallyDormant(_ project: some ProjectPathProviding) -> Bool {
        isManuallyDormant(path: project.path)
    }

    func isManuallyDormant(path: String) -> Bool {
        manuallyDormant.contains(path)
    }

    private func setManuallyDormant(_ newValue: Set<String>) {
        guard newValue != manuallyDormant else { return }
        manuallyDormant = newValue
        projectListPreferencesGateway.saveDormantProjectPaths(newValue)
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
        projectListPreferencesGateway.saveProjectOrder(normalizedOrder)

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
