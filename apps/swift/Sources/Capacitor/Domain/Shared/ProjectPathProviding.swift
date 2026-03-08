import Foundation

protocol ProjectPathProviding {
    var path: String { get }
}

protocol ShellProjectReferenceProviding: ProjectPathProviding {
    var shellProjectReference: ShellProjectReference { get }
}

extension Project: ProjectPathProviding {}
extension Project: ShellProjectReferenceProviding {
    var shellProjectReference: ShellProjectReference {
        ShellProjectReference(displayName: name, path: path)
    }
}

extension ShellProjectCatalogEntry: ProjectPathProviding {}
extension ShellProjectCatalogEntry: ShellProjectReferenceProviding {
    var shellProjectReference: ShellProjectReference {
        ShellProjectReference(
            id: id,
            displayName: displayName,
            path: path,
            workspaceId: nil,
        )
    }
}

extension ShellSuggestedProjectCandidate: ProjectPathProviding {}
extension ShellSuggestedProjectCandidate: ShellProjectReferenceProviding {
    var shellProjectReference: ShellProjectReference {
        ShellProjectReference(
            id: id,
            displayName: displayName,
            path: path,
            workspaceId: nil,
        )
    }
}

extension ShellProjectReference: ProjectPathProviding {}
extension ShellProjectReference: ShellProjectReferenceProviding {
    var shellProjectReference: ShellProjectReference {
        self
    }
}
