import Foundation

struct OperatorFieldOfWorkSection: Identifiable, Equatable {
    enum Kind: Equatable {
        case needsYou
        case runningNormally
        case recentlyChanged
        case dormantHidden

        var title: String {
            switch self {
            case .needsYou:
                "Needs You"
            case .runningNormally:
                "Running Normally"
            case .recentlyChanged:
                "Recently Changed"
            case .dormantHidden:
                "Dormant / Hidden"
            }
        }

        var cardActivityGroup: ActivityGroup {
            switch self {
            case .needsYou, .runningNormally, .recentlyChanged:
                .active
            case .dormantHidden:
                .idle
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let project: Project
        let attentionItem: OperatorAttentionItem?
        let isHidden: Bool

        var id: String {
            project.path
        }
    }

    let kind: Kind
    let rows: [Row]

    var id: Kind {
        kind
    }

    var title: String {
        kind.title
    }
}

enum OperatorFieldOfWorkProjection {
    static func make(
        projects: [Project],
        summary: OperatorAttentionSummary,
        projectOrder: [String],
        hiddenProjectPaths: Set<String>,
    ) -> [OperatorFieldOfWorkSection] {
        let orderedProjects = ProjectOrdering.orderedProjects(projects, customOrder: projectOrder)
        let projectsByPath = Dictionary(
            orderedProjects.map { (PathNormalizer.normalize($0.path), $0) },
            uniquingKeysWith: { first, _ in first },
        )
        let hiddenPaths = Set(hiddenProjectPaths.map(PathNormalizer.normalize))
        var consumedPaths = Set<String>()

        func rows(for items: [OperatorAttentionItem]) -> [OperatorFieldOfWorkSection.Row] {
            items.compactMap { item in
                let path = PathNormalizer.normalize(item.projectPath)
                guard !consumedPaths.contains(path),
                      let project = projectsByPath[path]
                else {
                    return nil
                }

                consumedPaths.insert(path)
                return OperatorFieldOfWorkSection.Row(
                    project: project,
                    attentionItem: item,
                    isHidden: hiddenPaths.contains(path),
                )
            }
        }

        let needsYou = rows(for: summary.needsYou + summary.exceptions)
        let runningNormally = rows(for: summary.runningNormally)
        let recentlyChanged = rows(for: summary.recentlyChanged)
        var dormantHidden = rows(for: summary.dormant)

        let fallbackRows = orderedProjects.compactMap { project -> OperatorFieldOfWorkSection.Row? in
            let path = PathNormalizer.normalize(project.path)
            guard !consumedPaths.contains(path) else { return nil }
            consumedPaths.insert(path)
            return OperatorFieldOfWorkSection.Row(
                project: project,
                attentionItem: nil,
                isHidden: hiddenPaths.contains(path),
            )
        }
        dormantHidden.append(contentsOf: fallbackRows)

        return [
            section(.needsYou, rows: needsYou),
            section(.runningNormally, rows: runningNormally),
            section(.recentlyChanged, rows: recentlyChanged),
            section(.dormantHidden, rows: dormantHidden),
        ].compactMap(\.self)
    }

    private static func section(
        _ kind: OperatorFieldOfWorkSection.Kind,
        rows: [OperatorFieldOfWorkSection.Row],
    ) -> OperatorFieldOfWorkSection? {
        guard !rows.isEmpty else { return nil }
        return OperatorFieldOfWorkSection(kind: kind, rows: rows)
    }
}
