import Foundation

enum ProjectMutationBridge {
    static func validationResult(from result: ValidationResultFfi) -> ShellProjectValidationResult {
        ShellProjectValidationResult(
            kind: validationKind(from: result.resultType),
            path: result.path,
            suggestedPath: result.suggestedPath,
            reason: result.reason,
            hasClaudeMd: result.hasClaudeMd,
            hasOtherMarkers: result.hasOtherMarkers,
        )
    }

    private static func validationKind(from resultType: String) -> ShellProjectValidationKind {
        switch resultType {
        case "valid":
            .valid
        case "suggest_parent":
            .suggestParent
        case "missing_claude_md":
            .missingClaudeMd
        case "not_a_project":
            .notAProject
        case "already_tracked":
            .alreadyTracked
        case "path_not_found":
            .pathNotFound
        case "dangerous_path":
            .dangerousPath
        default:
            .unknown
        }
    }
}
