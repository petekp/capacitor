import Foundation

@MainActor
final class WorkstreamsManager: ObservableObject {
    struct State: Equatable {
        var worktrees: [WorktreeService.Worktree] = []
        var isLoading = false
        var isCreating = false
        var destroyingNames: Set<String> = []
        var forceDestroyableNames: Set<String> = []
        var errorMessage: String?
    }

    typealias ListManagedWorktrees = (_ repoPath: String) throws -> [WorktreeService.Worktree]
    typealias CreateManagedWorktree = (_ repoPath: String, _ name: String) throws -> WorktreeService.Worktree
    typealias RemoveManagedWorktree = (_ repoPath: String, _ name: String, _ force: Bool, _ activePaths: Set<String>) throws -> Void
    typealias OpenWorktree = (_ project: Project) -> Void
    typealias ActiveWorktreePathsProvider = () -> Set<String>

    @Published private(set) var states: [String: State] = [:]

    private let listManagedWorktrees: ListManagedWorktrees
    private let createManagedWorktree: CreateManagedWorktree
    private let removeManagedWorktree: RemoveManagedWorktree
    private let openWorktree: OpenWorktree
    private let activeWorktreePathsProvider: ActiveWorktreePathsProvider

    init(
        listManagedWorktrees: @escaping ListManagedWorktrees = { repoPath in
            try WorktreeService().listManagedWorktrees(in: repoPath)
        },
        createManagedWorktree: @escaping CreateManagedWorktree = { repoPath, name in
            try WorktreeService().createManagedWorktree(in: repoPath, name: name)
        },
        removeManagedWorktree: @escaping RemoveManagedWorktree = { repoPath, name, force, activePaths in
            try WorktreeService().removeManagedWorktree(
                in: repoPath,
                name: name,
                force: force,
                activeWorktreePaths: activePaths,
            )
        },
        openWorktree: @escaping OpenWorktree = { _ in },
        activeWorktreePathsProvider: @escaping ActiveWorktreePathsProvider = { [] },
    ) {
        self.listManagedWorktrees = listManagedWorktrees
        self.createManagedWorktree = createManagedWorktree
        self.removeManagedWorktree = removeManagedWorktree
        self.openWorktree = openWorktree
        self.activeWorktreePathsProvider = activeWorktreePathsProvider
    }

    func state(for project: Project) -> State {
        states[project.path] ?? State()
    }

    func load(for project: Project) {
        mutateState(for: project.path) {
            $0.isLoading = true
            $0.errorMessage = nil
        }

        do {
            let worktrees = try listManagedWorktrees(project.path)
            mutateState(for: project.path) {
                $0.worktrees = worktrees
                $0.isLoading = false
                $0.errorMessage = nil
            }
        } catch {
            mutateState(for: project.path) {
                $0.worktrees = []
                $0.isLoading = false
                $0.errorMessage = Self.describe(error)
            }
        }
    }

    func create(for project: Project) {
        let current = state(for: project)
        var usedNames = Set(current.worktrees.map(\.name))
        var branchAlreadyExistsRetries = 0

        mutateState(for: project.path) {
            $0.isCreating = true
            $0.errorMessage = nil
        }

        do {
            while true {
                let nextName = Self.nextWorktreeName(for: project, from: usedNames)

                do {
                    _ = try createManagedWorktree(project.path, nextName)
                    let refreshed = try listManagedWorktrees(project.path)
                    mutateState(for: project.path) {
                        $0.worktrees = refreshed
                        $0.isCreating = false
                        $0.errorMessage = nil
                    }
                    return
                } catch {
                    guard Self.isBranchAlreadyExistsCreateError(error),
                          branchAlreadyExistsRetries < Self.maxCreateBranchAlreadyExistsRetries
                    else {
                        throw error
                    }

                    usedNames.insert(nextName)
                    branchAlreadyExistsRetries += 1
                }
            }
        } catch {
            mutateState(for: project.path) {
                $0.isCreating = false
                $0.errorMessage = Self.describe(error)
            }
        }
    }

    func destroy(worktreeName: String, for project: Project, force: Bool = false) {
        mutateState(for: project.path) {
            $0.destroyingNames.insert(worktreeName)
            $0.errorMessage = nil
        }

        do {
            try removeManagedWorktree(
                project.path,
                worktreeName,
                force,
                activeWorktreePathsProvider().map(PathNormalizer.normalize).reduce(into: Set<String>()) { set, path in
                    set.insert(path)
                },
            )
            let refreshed = try listManagedWorktrees(project.path)
            mutateState(for: project.path) {
                $0.worktrees = refreshed
                $0.destroyingNames.remove(worktreeName)
                $0.forceDestroyableNames.remove(worktreeName)
                $0.errorMessage = nil
            }
        } catch {
            let isActiveSession = Self.isActiveSessionError(error)
            mutateState(for: project.path) {
                $0.destroyingNames.remove(worktreeName)
                if isActiveSession {
                    $0.forceDestroyableNames.insert(worktreeName)
                }
                $0.errorMessage = Self.describe(error)
            }
        }
    }

    private static func isActiveSessionError(_ error: Swift.Error) -> Bool {
        if case WorktreeService.Error.activeSessionWorktree = error {
            return true
        }
        return false
    }

    func open(_ worktree: WorktreeService.Worktree) {
        openWorktree(Self.makeWorktreeProject(worktree))
    }

    private func mutateState(for projectPath: String, _ mutate: (inout State) -> Void) {
        var current = states[projectPath] ?? State()
        mutate(&current)
        states[projectPath] = current
    }

    private static let maxCreateBranchAlreadyExistsRetries = 100

    private static func nextWorktreeName(for project: Project, from names: Set<String>) -> String {
        let prefix = worktreePrefix(for: project)
        let used = Set(names.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else { return nil }
            let raw = name.dropFirst(prefix.count)
            return Int(raw)
        })

        var candidate = 1
        while used.contains(candidate) {
            candidate += 1
        }

        return "\(prefix)\(candidate)"
    }

    private static func worktreePrefix(for project: Project) -> String {
        let rawName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = rawName.isEmpty ? URL(fileURLWithPath: project.path).lastPathComponent : rawName
        let slug = slugify(source)
        return "\(slug)-workstream-"
    }

    private static func slugify(_ value: String) -> String {
        let transformed = value.lowercased().map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return "-"
        }

        var collapsed: [Character] = []
        for char in transformed {
            if char == "-", collapsed.last == "-" {
                continue
            }
            collapsed.append(char)
        }

        let slug = String(collapsed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "project" : slug
    }

    private static func isBranchAlreadyExistsCreateError(_ error: Swift.Error) -> Bool {
        guard case let WorktreeService.Error.gitCommandFailed(arguments, _, output) = error else {
            return false
        }

        guard arguments.starts(with: ["worktree", "add"]) else {
            return false
        }

        let normalizedOutput = output.lowercased()
        return normalizedOutput.contains("branch") && normalizedOutput.contains("already exists")
    }

    private static func makeWorktreeProject(_ worktree: WorktreeService.Worktree) -> Project {
        Project(
            name: worktree.name,
            path: worktree.path,
            displayPath: worktree.path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private static func describe(_ error: Swift.Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty
        {
            return description
        }
        return error.localizedDescription
    }
}
