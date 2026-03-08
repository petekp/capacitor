import Foundation

// MARK: - Activity Group

enum ActivityGroup: String {
    case active
    case idle
}

// MARK: - Ordering

enum ProjectOrdering {
    enum ActivityBand {
        case active
        case cooling
        case idle
    }

    private enum Constants {
        /// Keep newly-idle cards in the active ordering bucket briefly to avoid
        /// oscillating off-screen/on-screen movement when runtime state flaps.
        static let idleDemotionGraceSeconds: TimeInterval = 8
    }

    /// Returns projects split into (active, idle) groups using one global persisted order.
    /// Active projects always render first, while preserving relative order from `order`.
    static func orderedGroupedProjects<ProjectType: ProjectPathProviding>(
        _ projects: [ProjectType],
        order: [String],
        sessionStates: [String: ProjectSessionState],
        now: Date = Date(),
    ) -> (active: [ProjectType], idle: [ProjectType]) {
        let globallyOrdered = orderedProjects(projects, customOrder: order)

        var activeProjects: [ProjectType] = []
        var idleProjects: [ProjectType] = []
        activeProjects.reserveCapacity(globallyOrdered.count)
        idleProjects.reserveCapacity(globallyOrdered.count)

        for project in globallyOrdered {
            if isActive(project.path, sessionStates: sessionStates, now: now) {
                activeProjects.append(project)
            } else {
                idleProjects.append(project)
            }
        }

        return (active: activeProjects, idle: idleProjects)
    }

    /// Classifies a project as active if it has a session with a non-idle state.
    static func sessionState(for path: String, sessionStates: [String: ProjectSessionState]) -> ProjectSessionState? {
        if let session = sessionStates[path] {
            return session
        }

        let normalizedPath = PathNormalizer.normalize(path)
        return sessionStates.first(where: { PathNormalizer.normalize($0.key) == normalizedPath })?.value
    }

    /// Classifies a project as active for ordering purposes.
    /// Idle states are held in active briefly after transition to reduce list jitter.
    static func isActive(
        _ path: String,
        sessionStates: [String: ProjectSessionState],
        now: Date = Date(),
    ) -> Bool {
        guard let session = sessionState(for: path, sessionStates: sessionStates) else {
            return false
        }

        return activityBand(session, now: now) != .idle
    }

    static func activityBand(
        _ path: String,
        sessionStates: [String: ProjectSessionState],
        now: Date = Date(),
    ) -> ActivityBand {
        guard let session = sessionState(for: path, sessionStates: sessionStates) else {
            return .idle
        }

        return activityBand(session, now: now)
    }

    private static func activityBand(_ session: ProjectSessionState, now: Date) -> ActivityBand {
        switch session.state {
        case .working, .waiting, .compacting, .ready:
            return .active
        case .idle:
            guard
                let stateChangedAt = session.stateChangedAt,
                let changedAt = parseISO8601Date(stateChangedAt)
            else {
                return .idle
            }

            return now.timeIntervalSince(changedAt) < Constants.idleDemotionGraceSeconds ? .cooling : .idle
        }
    }

    static func orderedProjects<ProjectType: ProjectPathProviding>(
        _ projects: [ProjectType],
        customOrder: [String],
    ) -> [ProjectType] {
        guard !customOrder.isEmpty else { return projects }

        var result: [ProjectType] = []
        var remaining = projects

        for path in customOrder {
            if let index = remaining.firstIndex(where: { $0.path == path }) {
                result.append(remaining.remove(at: index))
            }
        }

        result.append(contentsOf: remaining)
        return result
    }

    static func movedGlobalOrder<ProjectType: ProjectPathProviding>(
        from source: IndexSet,
        to destination: Int,
        in projectList: [ProjectType],
        globalOrder: [String],
        allProjects: [ProjectType],
    ) -> [String] {
        guard !projectList.isEmpty else {
            return uniquePaths(globalOrder)
        }

        var movedGroupPaths = projectList.map(\.path)
        movedGroupPaths.move(fromOffsets: source, toOffset: destination)

        let groupSet = Set(projectList.map(\.path))
        let knownProjectPaths = allProjects.map(\.path)
        var result = uniquePaths(globalOrder)

        for path in knownProjectPaths where !result.contains(path) {
            result.append(path)
        }

        var replacementIndex = 0
        for index in result.indices where groupSet.contains(result[index]) {
            if replacementIndex >= movedGroupPaths.count { break }
            result[index] = movedGroupPaths[replacementIndex]
            replacementIndex += 1
        }

        return result
    }

    static func movedOrder(
        from source: IndexSet,
        to destination: Int,
        in projectList: [some ProjectPathProviding],
    ) -> [String] {
        movedGlobalOrder(
            from: source,
            to: destination,
            in: projectList,
            globalOrder: projectList.map(\.path),
            allProjects: projectList,
        )
    }

    /// Stable per-card container identity.
    /// Session-state transitions must not change this key, otherwise SwiftUI remounts card rows and
    /// replays insertion/removal transitions (visible fade/scale artifacts).
    static func cardIdentityKey(projectPath: String, sessionState: ProjectSessionState?) -> String {
        _ = sessionState
        return projectPath
    }

    /// Session-sensitive fingerprint for in-place card content refresh.
    /// Use this for inner content invalidation while keeping outer row identity stable.
    static func cardContentStateFingerprint(sessionState: ProjectSessionState?) -> String {
        guard let sessionState else {
            return "none"
        }

        return "\(sessionLabel(sessionState.state))#\(sessionState.sessionId ?? "-")#\(sessionState.hasSession ? "1" : "0")#\(sessionState.stateChangedAt ?? "-")"
    }

    private static func sessionLabel(_ state: SessionState) -> String {
        switch state {
        case .working:
            "working"
        case .ready:
            "ready"
        case .idle:
            "idle"
        case .compacting:
            "compacting"
        case .waiting:
            "waiting"
        }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
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

// MARK: - Persistence

enum ProjectOrderStore {
    private static let globalOrderKey = "projectOrder.global"
    private static let migrationKey = "projectOrder.migrated.v3"

    /// Legacy key (pre-v2)
    private static let legacyOrderKey = "customProjectOrder"
    private static let legacyActiveOrderKey = "projectOrder.active"
    private static let legacyIdleOrderKey = "projectOrder.idle"
    private static let legacyMigrationKey = "projectOrder.migrated.v2"

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        if let global = defaults.array(forKey: globalOrderKey) as? [String] {
            return uniquePaths(global)
        }

        let legacyActive = defaults.array(forKey: legacyActiveOrderKey) as? [String] ?? []
        let legacyIdle = defaults.array(forKey: legacyIdleOrderKey) as? [String] ?? []
        if !legacyActive.isEmpty || !legacyIdle.isEmpty {
            return uniquePaths(legacyActive + legacyIdle)
        }

        let legacyOrder = defaults.array(forKey: legacyOrderKey) as? [String] ?? []
        return uniquePaths(legacyOrder)
    }

    static func save(_ order: [String], to defaults: UserDefaults = .standard) {
        defaults.set(uniquePaths(order), forKey: globalOrderKey)
    }

    /// Migrates from pre-v3 keys to single global order.
    static func migrateIfNeeded(from defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationKey) else { return }

        let migratedOrder = load(from: defaults)
        if !migratedOrder.isEmpty {
            save(migratedOrder, to: defaults)
        }

        defaults.set(true, forKey: migrationKey)
        defaults.set(true, forKey: legacyMigrationKey)
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
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
