import Foundation

enum HealthGrade: String, Comparable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case f = "F"
    case none = "-"

    static func < (lhs: HealthGrade, rhs: HealthGrade) -> Bool {
        let order: [HealthGrade] = [.f, .d, .c, .b, .a]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}

struct HealthScoreResult {
    let grade: HealthGrade
    let score: Int
    let maxScore: Int
    let details: [HealthCheck]
}

struct HealthCheck {
    let name: String
    let passed: Bool
    let points: Int
    let suggestion: String?
    let template: String?
}

struct ClaudeMdHealthScorer {
    static func score(content: String?) -> HealthScoreResult {
        guard let content = content, !content.isEmpty else {
            return HealthScoreResult(
                grade: .none,
                score: 0,
                maxScore: 100,
                details: []
            )
        }

        var checks: [HealthCheck] = []
        let lowercased = content.lowercased()

        let hasDescription = checkDescription(content: lowercased)
        checks.append(HealthCheck(
            name: "Project Description",
            passed: hasDescription,
            points: hasDescription ? 25 : 0,
            suggestion: hasDescription ? nil : "Add a clear project description at the top",
            template: "## Overview\n\nBrief description of what this project does and its purpose.\n\n## Key Features\n\n- Feature one\n- Feature two\n"
        ))

        let hasWorkflow = checkWorkflow(content: lowercased)
        checks.append(HealthCheck(
            name: "Workflow/Commands",
            passed: hasWorkflow,
            points: hasWorkflow ? 20 : 0,
            suggestion: hasWorkflow ? nil : "Add common commands or workflow instructions",
            template: "## Workflow\n\n### Quick Start\n\n```bash\nnpm install\nnpm run dev\n```\n\n### Common Commands\n\n- `npm test` - Run tests\n- `npm run build` - Build project\n"
        ))

        let hasArchitecture = checkArchitecture(content: lowercased)
        checks.append(HealthCheck(
            name: "Architecture Info",
            passed: hasArchitecture,
            points: hasArchitecture ? 20 : 0,
            suggestion: hasArchitecture ? nil : "Document project structure and key files",
            template: "## Architecture\n\n```\nsrc/\n  components/\n  utils/\n  types/\ntests/\n```\n\n### Key Files\n\n- `src/main.ts` - Entry point\n- `package.json` - Dependencies\n"
        ))

        let hasStyleRules = checkStyleRules(content: lowercased)
        checks.append(HealthCheck(
            name: "Style/Conventions",
            passed: hasStyleRules,
            points: hasStyleRules ? 15 : 0,
            suggestion: hasStyleRules ? nil : "Add coding style guidelines or conventions",
            template: "## Style Guide\n\n- Use 2-space indentation\n- Prefer const over let\n- Always add JSDoc comments for public functions\n- Avoid long lines (max 100 chars)\n"
        ))

        let hasSubstance = content.count >= 200
        checks.append(HealthCheck(
            name: "Sufficient Detail",
            passed: hasSubstance,
            points: hasSubstance ? 20 : 0,
            suggestion: hasSubstance ? nil : "Add more detail (current: \(content.count) chars)",
            template: nil
        ))

        let totalScore = checks.reduce(0) { $0 + $1.points }
        let grade = gradeFromScore(totalScore)

        return HealthScoreResult(
            grade: grade,
            score: totalScore,
            maxScore: 100,
            details: checks
        )
    }

    private static func checkDescription(content: String) -> Bool {
        let patterns = [
            "## project",
            "# project",
            "this project",
            "overview",
            "purpose",
            "## about",
            "what it does",
            "description"
        ]
        return patterns.contains { content.contains($0) } || content.count > 100
    }

    private static func checkWorkflow(content: String) -> Bool {
        let patterns = [
            "```bash",
            "```shell",
            "## commands",
            "## scripts",
            "## workflow",
            "## development",
            "npm ",
            "pnpm ",
            "yarn ",
            "cargo ",
            "swift ",
            "make ",
            "## quick start",
            "## getting started"
        ]
        return patterns.contains { content.contains($0) }
    }

    private static func checkArchitecture(content: String) -> Bool {
        let patterns = [
            "## structure",
            "## architecture",
            "## project structure",
            "## directory",
            "## files",
            "## modules",
            "src/",
            "lib/",
            "packages/",
            "apps/",
            "components/",
            "## organization"
        ]
        return patterns.contains { content.contains($0) }
    }

    private static func checkStyleRules(content: String) -> Bool {
        let patterns = [
            "## style",
            "## conventions",
            "## code style",
            "## guidelines",
            "prefer ",
            "always ",
            "never ",
            "avoid ",
            "use ",
            "don't ",
            "## preferences",
            "## rules"
        ]
        return patterns.contains { content.contains($0) }
    }

    private static func gradeFromScore(_ score: Int) -> HealthGrade {
        switch score {
        case 90...100: return .a
        case 75..<90: return .b
        case 60..<75: return .c
        case 40..<60: return .d
        case 1..<40: return .f
        default: return .none
        }
    }
}
