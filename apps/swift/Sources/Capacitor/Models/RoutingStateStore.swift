import Foundation
import os.log

private let routingLogger = Logger(subsystem: "com.capacitor.app", category: "RoutingStateStore")

struct RuntimeRoutingView: Equatable {
    let workspaceId: String
    let projectPath: String
    let status: String
    let target: CoreRoutingTarget
    let reasonCode: String
    let reason: String
    let updatedAt: String
}

@MainActor
@Observable
final class RoutingStateStore {
    private(set) var routesByWorkspaceID: [String: RuntimeRoutingView] = [:]

    init() {}

    func applyRuntimeRoutingViews(
        _ routingViews: [RuntimeRoutingView],
        correlationId: String? = nil,
    ) {
        routesByWorkspaceID = Dictionary(
            uniqueKeysWithValues: routingViews.map { ($0.workspaceId, $0) },
        )
        let cid = correlationId ?? "none"
        let summary = routingViews
            .map { route in
                "\(route.workspaceId)=\(route.status):\(route.target.kind)"
            }
            .sorted()
            .joined(separator: " | ")
        routingLogger.info("Routing state updated: count=\(routingViews.count) summary=\(summary, privacy: .public)")
        DebugLog.write(
            "RoutingStateStore.applyRuntimeRoutingViews cid=\(cid) count=\(routingViews.count) summary=\(summary)",
        )
    }

    func clearRuntimeRoutingViews(correlationId: String? = nil) {
        routesByWorkspaceID = [:]
        let cid = correlationId ?? "none"
        routingLogger.info("Routing state cleared")
        DebugLog.write("RoutingStateStore.clearRuntimeRoutingViews cid=\(cid)")
    }

    func routingView(projectPath: String, workspaceId: String?) -> RuntimeRoutingView? {
        let trimmedWorkspaceId = workspaceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let workspaceId = trimmedWorkspaceId,
           !workspaceId.isEmpty,
           let route = routesByWorkspaceID[workspaceId]
        {
            return route
        }

        let normalizedProjectPath = PathNormalizer.normalize(projectPath)
        return routesByWorkspaceID.values.first(where: {
            PathNormalizer.normalize($0.projectPath) == normalizedProjectPath
        })
    }
}
