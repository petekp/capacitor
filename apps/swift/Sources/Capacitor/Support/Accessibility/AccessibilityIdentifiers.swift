import Foundation

enum AccessibilityIdentifiers {
    static let backProjectsIdentifier = "ax.nav.back-projects"

    static func projectCardIdentifier(for project: some ShellProjectReferenceProviding) -> String {
        "ax.project-card.\(slug(for: project))"
    }

    static func projectDetailsIdentifier(for project: some ShellProjectReferenceProviding) -> String {
        "ax.project-details.\(slug(for: project))"
    }

    static func slug(for project: some ShellProjectReferenceProviding) -> String {
        let candidate = URL(fileURLWithPath: project.path).lastPathComponent
        let source = candidate.isEmpty ? project.shellProjectReference.displayName : candidate

        let slug = source
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return slug.isEmpty ? "project" : slug
    }
}
